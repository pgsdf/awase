# AD-12 Service lifecycle verification

Status: Stated, 2026-05-05.

This document is the verification sign-off for AD-12 (Service
lifecycle: starts, stops, and dependency ordering). AD-12 is
considered substantially complete when the four verification items
in BACKLOG.md AD-12.6 have been tested with results recorded here.
Items not yet tested are listed explicitly so the gaps are visible
rather than hidden.

The AD-12 sub-stages whose work this doc verifies:

- **AD-12.1** install.sh stop-before-copy with atomic rename and
  post-install restart in dependency order.
- **AD-12.2** rc.d REQUIRE/PROVIDE corrections (abstract capability
  names, FILESYSTEMS replacing LOGIN, dependency direction
  fixed for semainput vs semadraw).
- **AD-12.3** inputfs rc.d service (REQUIRE: FILESYSTEMS, no manual
  `kldload` ever needed).
- **AD-12.4** rc.d stop-with-confirmation (SIGTERM-wait-SIGKILL,
  preserve pidfile on SIGKILL failure).
- **AD-12.5** daemon-under-dependency-absence ADR
  (`docs/UTF_DAEMON_DEPENDENCY_ABSENCE.md`). Policy only; no code.

## 1. rc.d ordering at boot

**Goal:** boot a clean PGSD system, observe rc.d auto-ordering
brings up inputfs, then semaaud, then semadraw, then semainput, in
that order, with no manual operator intervention. Confirm the
substrate ring exists before any daemon that reads it starts.

### Verified (yesterday, 2026-05-04)

Verified across reboot on PGSD bare-metal:

- `inputfs.ko` loaded automatically by rc.d before the daemons.
  `dmesg | grep inputfs` showed all six HID devices attached:
  ELECOM mouse, HAILUCK touchpad keyboard, HAILUCK touchpad
  mouse, Broadcom Bluetooth keyboard, Broadcom Bluetooth mouse,
  Apple keyboard. Six devices owned by inputfs.
- `/var/run/sema/input/{state,events}` files present, populated.
  inputdump confirmed `last_seq` advancing under real input.
- semaaud, semadraw, semainput all started with no manual
  `service X start` invocation.

### Verified (today, 2026-05-05)

After AD-12.4 and AD-12.2 landed:

- `service semaaud start` then `service semaaud stop` produced
  the expected sequence: "Stopping semaaud." ... "Stopped
  semaaud." with the second message printed only after the
  daemon actually exited (operator confirmed: pgrep returned
  empty after the stop returned).

### Not yet verified

- **Full reboot with the AD-12.2 PROVIDE/REQUIRE changes.**
  Yesterday's reboot tested AD-12.3's tags. AD-12.2's
  abstract-capability tags (utf_clock, inputfs_loaded) and the
  semainput/semadraw dependency direction reversal have not
  been exercised across a real reboot. `rcorder(8)` produces
  the expected order from the static rc.d files, but a true
  cold boot would confirm the ordering produces the right
  substrate state at the moment each daemon starts.

  Recommended verification: `sudo reboot`, after boot run
  `service inputfs status; service semaaud status; service
  semadraw status; service semainput status` — all should
  show running. `dmesg | grep inputfs` should show six HID
  devices attached. `inputdump state | head` should show
  `magic: INST` and `last_seq > 0`.

## 2. install.sh upgrade path

**Goal:** with the system running (daemons active, inputfs
loaded), running `sudo sh install.sh` should:

- Stop the running daemons cleanly (SIGTERM, wait, SIGKILL on
  timeout).
- Replace binaries atomically (no partial-replacement window).
- Optionally refresh inputfs.ko if it was loaded before install.
- Restart the daemons in dependency order.
- Leave a fully-operational system with no operator intervention.

### Verified (yesterday, 2026-05-04)

Tested on PGSD bare-metal:

- install.sh stopped semaaud, semainput, semadraw before
  copying new binaries.
- Atomic rename via .NEW.$$ → final path produced no partial
  replacement.
- Post-install restart sequence produced semaaud, semadraw,
  semainput started in that order.
- After install.sh completed, all daemons were running. inputdump
  showed substrate ring valid. semadraw-term connected
  successfully (Debug-mode, per AD-14 workaround).

### Partially verified

- **inputfs.ko refresh path (INPUTFS_WAS_LOADED branch).**
  Yesterday's first install attempt did not show "unloaded
  inputfs / loaded inputfs" lines in the install output, even
  though inputfs was loaded. A subsequent manual reload (kldunload
  / kldload) was required for AD-13.1 sysctl to appear. The
  detection logic uses `kldstat -q -m inputfs` at install start;
  whether it returned the wrong answer or whether the refresh
  block was skipped for another reason is undiagnosed.

  Recommended verification: with inputfs loaded, run install.sh
  with `set -x` enabled and confirm the INPUTFS_WAS_LOADED branch
  fires. If it does not, file as a sub-bug of AD-12.1.

### Not yet verified

- **Upgrade with daemons stopped.** install.sh tested only against
  a system where daemons were already running. The "install on a
  fresh system" path was tested at original install time but not
  retested with the AD-12.2/AD-12.4 changes.

  Recommended verification: `sudo service semadraw stop; sudo
  service semainput stop; sudo service semaaud stop`, then run
  `sudo sh install.sh`. Should not error on stop attempts for
  already-stopped services. Should restart the services that
  were running before (which is none; the post-install restart
  block should be a no-op).

## 3. SIGTERM-then-SIGKILL stop behaviour

**Goal:** verify that the AD-12.4 stop-with-confirmation logic
correctly escalates to SIGKILL when SIGTERM is ignored, and
preserves the pidfile if SIGKILL also fails (vanishingly rare,
but the failure mode should not leave the pidfile in an
inconsistent state).

### Verified (today, 2026-05-05)

Operator confirmed normal-stop path on bare-metal:

- `sudo service semaaud start` produced a running daemon with
  pidfile.
- `sudo service semaaud stop` printed "Stopping semaaud." and
  "Stopped semaaud." with the daemon actually gone after the
  command returned (pgrep empty).
- pidfile cleaned up after successful stop.

### Not yet verified

- **SIGKILL escalation path.** The path that fires when SIGTERM
  is ignored has not been exercised. The simplest test is to
  freeze the daemon with `pkill -STOP` (SIGSTOP is uncatchable;
  the daemon cannot install a handler), then run `service stop`,
  observe the SIGKILL escalation:

  ```
  sudo service semaaud start
  sudo pkill -STOP semaaud
  sudo service semaaud stop
  # expect on stderr: "semaaud did not exit within 5s, sending SIGKILL."
  pgrep semaaud
  # expect: no output (SIGKILL is uncatchable; daemon dies)
  ```

- **Pidfile preservation when SIGKILL also fails.** This requires
  a daemon in a kernel-uninterruptible state (waiting on a
  hardware event that never completes), which is not easy to
  arrange synthetically. Realistic exposure: kernel hangs are
  visible in `procstat -kk`. The pidfile-preservation behaviour
  is a defensive correctness property; operator can verify the
  code path by inspection in install.sh's generated rc.d
  scripts.

## 4. Deliberate-misordering test (AD-12.5 ADR enforcement)

**Goal:** verify that semadrawd in degraded mode (started before
inputfs has loaded) advertises the absence of the input
substrate to clients rather than silently doing nothing — the
behaviour the AD-12.5 ADR requires for Posture 3.

### Not yet verified — also not yet implemented

This test exercises behaviour that does not exist in the
codebase. semadrawd's current dependency-absence handling falls
into Posture 1 (silent retry without advertising), which the
AD-12.5 ADR forbids. The implementation work to bring semadrawd
into Posture 3 compliance is sketched in the ADR's
"Implementation outlook" section as the first concrete item; it
has not landed.

Recommended sequence once Posture 3 is implemented:

1. `sudo service semadraw stop; sudo service inputfs stop`
2. `sudo service semadraw start` (should succeed; semadrawd
   should bind its socket and accept connections).
3. Client connect: degraded-mode advertising should appear in
   the `hello` response. Operator-visible log line should fire
   in dmesg or /var/log/messages.
4. `sudo service inputfs start`. semadrawd should detect the
   substrate appearing on its retry tick and broadcast a state
   transition to all connected clients.
5. Client should see the transition and re-enable input
   handling.

This verification stays open as a sub-task of the
Posture-3-implementation work referenced in the ADR.

## What this verification does not cover

- **AD-14 release-mode panic state.** semadraw-term release-mode
  panics yesterday were intermittent today; AD-14.1 lldb attempt
  produced non-reproduction. Whether the AD-12 work materially
  affected that bug class is not testable until the bug
  reproduces reliably again. AD-12 closure does not depend on
  AD-14 outcome.

- **Long-running stability.** No 24-hour or longer run has been
  done. Substrate-side daemons could accumulate state errors
  over time that short-test verification would not catch. This
  is general-systems-engineering work outside AD-12's scope.

- **Crash recovery.** What happens if semadrawd panics mid-flight
  and rc.d restart-on-failure brings it back. Not exercised. The
  AD-12.5 ADR contemplates this in Posture 2; no specific test.

- **The `--upgrade` path with version drift.** install.sh has been
  exercised against in-tree versions only. A scenario where the
  installed binary is an older version than the source tree
  would test the full upgrade flow; not yet exercised.

## Sign-off

AD-12 is **substantially complete** as of 2026-05-05.

Five of six sub-stages (12.1, 12.2, 12.3, 12.4, 12.5) have
landed. AD-12.6 (this document) records the verification state.

The verification gaps named above are operator-runnable when
convenient; they do not require new code (with the exception of
the deliberate-misordering test, which depends on the Posture 3
implementation work). Filing them as named gaps rather than
hiding them under a blanket sign-off makes the actual coverage
visible to anyone reading this doc later.

The pattern this doc establishes for cross-component verification
docs: list verified items with date and what was confirmed; list
partially-verified items with what's missing; list unverified
items with the recommended verification sequence; explicitly note
what is out of scope. This format makes the verification state
re-readable and supports incremental verification (add to the
"Verified" section as gaps close, rather than re-verifying
everything when one piece changes).

## References

- `BACKLOG.md` AD-12 — the lifecycle work this doc verifies.
- `docs/UTF_DAEMON_DEPENDENCY_ABSENCE.md` — the AD-12.5 ADR whose
  enforcement test (item 4) cannot run until Posture 3 is
  implemented.
- `docs/FAILURE_MODES.md` — where per-failure-mode documentation
  lives; complementary to this doc's verification focus.
- `INSTALL.md` — operator-facing install procedure; the
  procedure verified by item 2 above.
