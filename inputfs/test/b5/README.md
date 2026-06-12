# inputfs/test/b5

Verification scripts for Stage B.5 (per-device role classification,
ADR 0010). Companion to `inputfs/docs/B5_VERIFICATION.md`.

## Files

- `b5-common.sh`: shared shell library: precondition checks, build,
  install, dmesg capture, lifecycle helpers, and per-signal
  acceptance checks. Sourced by both driver scripts.
- `b5-verify-vm.sh`: runs Pass 1 (GhostBSD on Oracle VirtualBox).
  Pauses for VirtualBox USB pass-through actions.
- `b5-verify-baremetal.sh`: runs Pass 2 (bare-metal GhostBSD).
  Resolves the `hms`/`hkbd` conflict before running. Pauses for
  physical plug/unplug actions.

## What the scripts do automatically

- Verify the B.5 patch is applied (greps for the macros, the softc
  field, the helper, and the new `device_printf`).
- Build the module (`make clean && make`).
- Install (`sudo make install`).
- Confirm `inputfs.ko` is fresh in `/boot/modules/`.
- Clear the dmesg buffer between signals so per-signal log files
  are clean.
- Load and unload the module at the right times.
- Issue `devctl rescan` against `usbhid1`/`hidbus1` (or auto-discover).
- Capture inputfs lines from dmesg into `b5-N.M.log` files.
- Run first-pass acceptance checks per signal: `roles=` line is
  present, attach-sequence ordering is right, report stream has
  enough lines, unload is clean.
- Concatenate per-signal logs into `b5-pass1-vm.log` or
  `b5-pass2-baremetal.log`.

## What the scripts do not do

- Decide whether a verification is acceptable. The scripts do
  first-pass mechanical checks. The human reads the log files and
  makes the final call against the acceptance checkboxes in
  `B5_VERIFICATION.md`. Automated dmesg parsing is a hint, not a
  judgment.
- Perform any USB action. VirtualBox pass-through and physical
  plug/unplug remain manual. The scripts pause and prompt.
- Recover from a kernel panic. If a signal panics the kernel,
  capture `/var/crash` before rebooting and follow the failure
  handling section of `B5_VERIFICATION.md`.

## Usage

From any directory you want logs written into:

```
sh /path/to/inputfs/test/b5/b5-verify-vm.sh
```

or

```
sh /path/to/inputfs/test/b5/b5-verify-baremetal.sh
```

Logs are written into the current working directory, not into the
script's directory. This keeps verification artifacts separate from
the source tree (and out of the repo unless you choose to commit
them).

Exit codes:

- `0` = all four signals passed automated checks.
- `1` = at least one signal failed an automated check. Logs still
  written; review them.
- `2` = a precondition failed (patch missing, build broken, etc.).
- `3` = user aborted at a prompt.

## Why two scripts and not one

The VM and bare-metal procedures diverge in three places: USB
pass-through versus physical plug/unplug, the `hms`/`hkbd` conflict
that only matters on bare metal, and log file naming. Forking the
driver scripts is cleaner than threading a `--mode` flag through
half a dozen branch points. The shared logic lives in
`b5-common.sh`.

## Why the scripts pause for human confirmation

USB pass-through is not scriptable from inside the guest. Physical
plug/unplug on bare metal is not scriptable at all. Trying to fully
automate around these constraints would either lie about coverage
or reduce ergonomics to a series of `read -p` prompts no better
than what the scripts do today. The pause-and-prompt design admits
the constraint and gives the human a clear "act now" signal at the
moments that matter.

## After a successful pass

Follow the closeout section of `B5_VERIFICATION.md`:

1. Edit `BACKLOG.md` AD-1 Stage B block: flip B.5 from "not
   started" to "landed, verified on ..." with the captured vendor
   and product IDs.
2. Bump the "ADRs 0001 through 0009" preamble to "0010" if the
   ADR was added since the previous closeout.
3. Attach `b5-pass1-vm.log` and `b5-pass2-baremetal.log` to the
   commit message or paste excerpts.

## After a failed pass

Do not flip BACKLOG.md. Capture the failing log plus a full dmesg
(`sudo dmesg > b5-FAIL-full.log`) and consult the failure handling
section of `B5_VERIFICATION.md` for the four common B.5-specific
failure fingerprints. Most can be diagnosed from the dmesg alone.
