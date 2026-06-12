# 0013 Publication file permissions

## Status

Decided, 2026-04-29.

This ADR establishes the permission model for UTF's substrate
publication files (`/var/run/sema/input/state`,
`/var/run/sema/input/events`, `/var/run/sema/input/focus`,
`/var/run/sema/clock`) and is implemented in the same commit
that lands it.

## Context

UTF's input substrate publishes two file-backed shared-memory
regions from the kernel: `state` (current pointer position,
button state, device inventory, transform_active flag) and
`events` (the event ring with motion, button, scroll,
key_up/down, and Stage D.4 enter/leave events). A third
region is written by userspace and read by the kernel:
`focus` (surface map, keyboard focus, pointer grab). The
chronofs clock region sits alongside as
`/var/run/sema/clock` (sample-position counter, written by
semaaud, read by chronofs consumers).

These files are the substrate for input event delivery. The
events ring in particular contains every keystroke
(HID usage codes, modifier state) emitted by every keyboard
attached to the system, regardless of which session received
it.

Before this ADR, both kernel and userspace publishers created
files with mode `0644`: the kernel via explicit `vn_open`
mode argument, and userspace via Zig's
`std.fs.createFileAbsolute` defaulting to `0666` minus typical
umask (022) producing `0644`. Files were owned by root (for
kernel-created) or by the user that started the publisher
(for userspace-created). The result was world-readable input
event files, including keystrokes.

The drawfs cdev sits in adjacent territory and already used a
stricter convention: `root:wheel:0600` by default, with
sysctl tunables (`hw.drawfs.dev_uid`, `hw.drawfs.dev_gid`,
`hw.drawfs.dev_mode`) that operators set at module load to
relax for specific deployment scenarios. The drawfs precedent
is sound and was adopted as the model for this ADR rather
than introducing a parallel UTF-specific convention.

## Decision

Adopt drawfs's convention uniformly across UTF substrate
publication files.

### Kernel side (inputfs)

inputfs gains three sysctl tunables, modelled after drawfs's:

- `hw.inputfs.dev_uid` (default `0`)
- `hw.inputfs.dev_gid` (default `0`)
- `hw.inputfs.dev_mode` (default `0600`)

All three are `CTLFLAG_RWTUN`, settable from
`/boot/loader.conf` for module-load-time defaults and from
`sysctl(8)` for live runtime adjustment. The mode value is
masked with `07777` before use.

Each `vn_open(O_CREAT)` call in inputfs is followed
immediately by an `inputfs_apply_attrs` helper that calls
`VOP_SETATTR` with the configured uid/gid/mode while the
vnode is still exclusively locked from `vn_open`. The mode
passed to `vn_open` itself is also `inputfs_dev_mode` (so
even before `VOP_SETATTR` runs, the file is created with the
intended mode rather than 0644).

Two file-creation sites are affected:

- `inputfs_state_open_file` for `/var/run/sema/input/state`
- `inputfs_events_open_file` for `/var/run/sema/input/events`

The focus file is opened read-only (no `O_CREAT`); the
compositor creates it from userspace and is responsible for
its attributes.

`VOP_SETATTR` failure is logged but non-fatal: the file
remains with whatever attributes `vn_open` established and
the kthread continues to sync data. Consumers that cannot
read it will get `EACCES` at open time, which is the
expected failure path for a misconfigured deployment rather
than a substrate fault.

### Userspace side (Zig publishers)

Three publishers in `shared/src/`:

- `ClockWriter.init` (semaaud writes `/var/run/sema/clock`)
- `StateWriter.init` (test code writes `state`)
- `EventRingWriter.init` (test code writes `events`)
- `FocusWriter.init` (semadraw writes `focus`)

Each `std.fs.createFileAbsolute` call gains an explicit
`.mode = 0o600` field. Operators relax for multi-user
deployment via the OS's daemon-startup machinery rather
than via UTF-specific configuration:

- The daemon's effective group is set via `daemon_group` in
  `/etc/rc.conf` for each rc.d script
  (`semaaud_group=operator`, etc.). `rc.subr` calls
  `setgroups` before exec; the publisher process inherits
  that group as its effective gid. Files it creates are
  owned by that group.
- The daemon's umask is set via `umask` in the rc.d script
  (or via `${name}_umask` in `/etc/rc.conf`). Setting
  `umask 027` together with the explicit `0o600` produces
  files at `0600` (umask cannot expose bits, only clear
  them). Setting `umask 037` together with explicit
  `0o640` produces group-readable files.

This keeps UTF code minimal: the policy lives at the
operating-system layer where it belongs. UTF's job is to
ensure the file is *created* tightly (0600 default); the
operator's job is to relax it via the OS's existing tools.

### What is not changed

semaaud's runtime-state files at `/tmp/draw/audio/<target>/`
(state, policy, capabilities, last-event, etc.) are
diagnostic-surface files for UI inspection, not substrate
publication. They live under `/tmp` with its sticky-bit
parent-directory semantics, are intended for UI consumers
running as the same user as semaaud, and are out of scope
for this ADR. Their permissions remain whatever Zig's
default produces (currently 0644 via umask). If they ever
become more sensitive, that is a separate decision.

The directory mode `0755` for `/var/run/sema` and
`/var/run/sema/input` is also unchanged. Directory listing
reveals the file names but not contents; the existence of
the substrate is part of the system's public surface, like
the existence of `/dev/null`.

## Threat model

The threats this ADR addresses:

1. **Cross-user keystroke disclosure.** User B reads
   `/var/run/sema/input/events` and recovers user A's typed
   characters. Mitigated: with mode `0600` and root
   ownership, only root can read.
2. **Cross-user pointer / device disclosure.** User B reads
   `/var/run/sema/input/state` and learns user A's cursor
   position, button presses, and connected device metadata.
   Same mitigation.
3. **Cross-user focus / clock inference.** User B reads
   `/var/run/sema/input/focus` or `/var/run/sema/clock` and
   learns user A's surface layout, focus state, or audio
   stream presence. Same mitigation.

Threats this ADR does not address:

- **Privileged compromise.** A process running as root, or a
  loaded kernel module, has unrestricted access regardless
  of file mode. UTF's discipline assumes the kernel is
  trusted; mitigations against compromised kernels are out
  of scope.
- **Side-channel inference.** A process without read access
  may infer some input activity through scheduling
  artefacts, file timestamps, or other side channels. UTF
  does not aim to mitigate these.
- **Physical access.** Anyone with console access bypasses
  this entirely. Out of scope.

## Consequences

**Positive:**

- Keystroke data is not readable across user boundaries on a
  multi-user system.
- The model is uniform with drawfs's existing convention.
  Operators learn one pattern and apply it everywhere.
- Operators retain control: sysctls relax the kernel-side
  defaults; rc.conf relaxes the userspace-side defaults.
  No UTF-specific group identifier is imposed.
- Implementation surface is small: three new sysctls, one
  helper function (~25 lines), four `.mode = 0o600`
  additions. No new module dependencies.

**Negative:**

- The current dev workflow now requires `sudo` (or
  membership in a group the operator configures) to read
  publication files via tools like `inputdump` and
  `chrono_dump`. In practice this was already the case:
  every invocation in recent verification work was already
  preceded by `sudo`. Confirmed: no actual workflow break.
- C.5's verification script already runs as root via
  `sudo sh c-verify.sh`, so it is unaffected.
- Operators on multi-user systems must read the README's
  multi-user-deployment section to relax the defaults
  appropriately. This is a small documentation burden that
  could become an FAQ item if UTF gains broader adoption.

**Neutral:**

- Mode `0600` is a standard pattern for sensitive
  per-machine state files (cf. private SSH keys,
  `/var/db/freebsd-update/`'s state). Well understood by
  operators.
- No wire-format change. Permissions are entirely
  metadata; the byte content of every file is unchanged.

## Notes

This ADR was prompted by a publication-file permission
audit performed during cross-cutting work after Stage D.4.
The audit found uniform 0644 / world-readable permissions
across modules, undocumented and likely a holdover from
the convenience of single-user dev iteration during
Stages A–C. The decision to adopt drawfs's convention was
driven by the existing precedent in the same codebase,
the smaller implementation surface, and the operator's
freedom to choose any group rather than a UTF-imposed one.

The implementation lands in the same commit that introduces
this ADR.
