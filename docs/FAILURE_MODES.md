# Awase Failure Modes

Status: Stated, 2026-04-29. Updated 2026-06-05 for the post-F.6
stack: the clock writer is the audiofs kernel module (F.4, ADR
0018), the audio daemon is semasound under s6 supervision, and
the semaaud-era entries are replaced.

This document catalogs the runtime failure modes of Awase
substrates. Each entry names a mode, describes what triggers
it, gives the log signal an operator can grep for, states
how Awase responds, and explains how to recover.

The catalog is meant for operators and contributors. It is
not exhaustive: software bugs (assertion failures, kernel
panics from broken hardware, build errors) are out of scope
here. Those are bugs to fix, not modes to document. What is
in scope is the set of runtime conditions Awase deliberately
handles, where the response is part of the design rather
than an accident.

The modes are grouped by substrate. Within each group, modes
are ordered roughly by frequency (most common first).

## chronofs

### Clock file absent at reader startup

**Trigger.** A reader (semadraw or a chronofs diagnostic
tool) opens the clock at `/var/run/sema/clock` before the
audiofs kernel module has loaded and published it.

**Signal.** No log line; `Clock.init(path)` returns a
`Clock` in invalid state.

**Response.** `Clock.isValid()` returns false on every
reader. All reads return 0. Consumers that derive from
`samples_written` see 0 samples elapsed, which produces
zero-length intervals and time-snapping behaviour rather
than divisions by zero.

**Recovery.** Load the module (`service audiofs start`).
The clock file appears, `clock_valid` flips to 1, all
readers see live data on the next read. No reader-side
restart is required.

### Audio xrun (sample skip)

**Trigger.** The device drains the audiofs user ring faster
than the broker refills it (a starvation event); audiofs
detects the shortfall at the user-ring boundary (ADR 0017)
and raises an xrun.

**Signal.** semasound observes the xrun via the F.2
notify/events ring and continues (F.5.a observe-and-continue);
the event appears on the per-target events surface and
`last-event` under `/var/run/sema/audio/<target>/`. The
kernel's refill-miss counters (ADR 0023, permanent
observability) record the boundary behaviour.

**Response.** The clock keeps reporting `samples_written`
as the canonical position. Readers that derive a wall-clock
time from samples experience a jump (forward or backward)
proportional to the xrun. Consumers that handle this
explicitly (semadraw's frame scheduler, per Thoughts.md)
apply the three graphics strategies (frame interpolation,
frame skipping, time snapping) to absorb the discontinuity.

**Recovery.** xruns are transient. The clock continues
advancing once the audio stream recovers. No operator
action is required for occasional xruns; chronic xruns
indicate a pacing or load problem: check the refill-miss
counters first (the ADR 0022/0023 hum investigation is the
worked example of that diagnosis).

### Clock writer stops (audiofs module unloaded or stream idle)

**Trigger.** The audiofs module is unloaded (`kldunload`),
or no stream is active so no frames are being clocked out.
The kernel writer is not a process and does not crash the
way the old userland writer could; the failure surface is
module lifecycle and stream state.

**Signal.** No automatic signal at the clock-region level:
`clock_valid` remains 1 (it is never reset once set), and
`samples_written` stops advancing.

**Response.** Readers cannot distinguish "clock paused"
from "writer gone" by inspecting a single read. A consumer
that needs to detect this polls `samples_written` for
staleness over a known interval (the same staleness
doctrine ADR 0028 applies to broker liveness via
`publish_ts`), or checks `kldstat -q -n audiofs.ko`.

**Recovery.** Reload the module (`service audiofs start`)
if it was unloaded; otherwise start a stream. The counter
is monotonic and non-resetting across stop-start (F.4
closure evidence: verified across 70 load/unload cycles),
so readers resume on the next advance with no
discontinuity handling beyond the pause itself.

## inputfs

### drawfs not loaded at inputfs MOD_LOAD

**Trigger.** inputfs loads before drawfs, or drawfs is
not loaded at all.

**Signal.**
```
inputfs: drawfs sysctl hw.drawfs.efifb.width unavailable; using defaults
inputfs: D.3 transform inactive (geometry not available); pointer reports raw accumulated deltas
```

**Response.** Stage D.2 geometry-read falls back to
conservative defaults (1024x768). Stage D.3 sees
`inputfs_geom_known == 0`, leaves `transform_active = 0`
in the state header, and runs the pointer accumulator
unclamped (Stage C semantics preserved). Pointer events
carry raw accumulated deltas that grow without bound.

**Recovery.** Load drawfs first
(`kldload drawfs`), then unload and reload inputfs. The
geometry read succeeds at MOD_LOAD, transform_active flips
to 1, the pointer is seeded at the display centre.

### Focus file absent (compositor not running)

**Trigger.** inputfs loads with no compositor running, so
`/var/run/sema/input/focus` does not exist.

**Signal.**
```
inputfs: focus file /var/run/sema/input/focus not present (compositor not running?); will retry
```

**Response.** The focus kthread retries periodically.
inputfs operations continue: pointer events accumulate,
publish to state and events regions normally. All events
get `session_id = 0` because the focus cache stays
invalid (D.4 routing falls through). No leave/enter
synthesised. Bit-for-bit compatible with pre-D.4 behaviour
for consumers that read events.

**Recovery.** Start the compositor (`service semadrawd
start`). The compositor creates the focus file. inputfs's
next refresh tick reads it, marks the cache valid, and
subsequent events carry derived session_ids.

### Focus file mid-update (seqlock odd)

**Trigger.** inputfs reads the focus file while the
compositor is mid-write, captured as an odd seqlock
counter.

**Signal.** No log line; the condition is observed and
handled silently.

**Response.** The narrow helpers
(`inputfs_focus_resolve_pointer`,
`inputfs_focus_keyboard_session`) return `session_id = 0`
for that report. The next kthread refresh re-reads the
file; if the writer has finished, the new read is
consistent and routing resumes.

**Recovery.** Self-healing. No operator action required.

### vn_open of state or events file fails

**Trigger.** The `/var/run/sema` tree is not writable
(e.g. tmpfs full, mount point missing, filesystem
read-only).

**Signal.**
```
inputfs: vn_open(/var/run/sema/input/state) failed: <errno> (continuing without file sync)
inputfs: vn_open(/var/run/sema/input/events) failed: <errno> (continuing without events file sync)
```

**Response.** inputfs marks the corresponding
`*_vp = NULL`, the kthread silently skips file syncs for
that region. The kernel's live in-memory buffer stays
correct and continues to receive event publications, but
no userspace consumer can read them. Module load
otherwise succeeds; HID device attachment continues
normally.

**Recovery.** Fix the underlying condition (free space on
tmpfs, mount the right filesystem, remount writable),
then unload and reload inputfs. The vn_open succeeds on
the second attempt.

### VOP_SETATTR fails after vn_open

**Trigger.** Per ADR 0013, inputfs stamps uid/gid/mode on
publication files via `VOP_SETATTR` after `vn_open`. If
the underlying filesystem rejects the operation (rare on
tmpfs, possible on exotic mounts), the call returns
non-zero.

**Signal.**
```
inputfs: VOP_SETATTR(<path>) failed: <errno> (file remains with vn_open default attributes)
```

**Response.** The file stays open and writable; the
kthread continues syncing to it. Attributes remain
whatever `vn_open` set (typically root:wheel:0600 from
the mode argument, but possibly looser if the filesystem
applied umask or other mutations). The mismatch with
intended attributes is logged; consumers that fail to
open the file get EACCES, which is the expected failure
path for misconfiguration.

**Recovery.** Diagnose the underlying filesystem
behaviour. tmpfs honours VOP_SETATTR; if the mount is on
something else, evaluate whether that filesystem is
appropriate for `/var/run/sema/`.

### HID device hotplug (unplug during active session)

**Trigger.** A user unplugs a USB keyboard or mouse
mid-session.

**Signal.** Standard FreeBSD hidbus detach lines, plus:
```
inputfs: device <slot> detached (slot zeroed)
```

**Response.** The detach handler clears the device slot
in the state region's device inventory, decrements
`device_count`. If the unplugged device was the only
keyboard or only pointer, subsequent reports of that
class stop arriving. The state region's `pointer_x` /
`pointer_y` retain their last value (the cursor does not
reset). No spurious leave/enter is synthesised.

**Recovery.** Replug or attach a different device of the
same class. The new device gets a new slot and starts
contributing reports. If the unplugged device returns,
its identity_hash matches the existing slot pattern but
the slot has been zeroed; it gets a fresh slot.

### HID device hotplug (plug during active session)

**Trigger.** A user plugs a new USB input device.

**Signal.** Standard FreeBSD hidbus attach lines, plus:
```
inputfs: device <slot> attached: vendor=0x<...> product=0x<...> roles=0x<...>
```

**Response.** The attach handler allocates a free slot
in the state region, populates the slot fields, emits a
`lifecycle.attach` event. Reports from the new device
contribute to the global cursor / keyboard accumulator
immediately.

**Recovery.** Self-handled. No operator action.

### Module unload mid-operation

**Trigger.** `kldunload inputfs` while pointer or
keyboard events are arriving.

**Signal.** Standard kldunload sequence. dmesg shows the
module unloading.

**Response.** MOD_UNLOAD detaches all hidbus children
(stopping new reports), tears down the kthread, closes
publication file vnodes, and frees module-global memory.
In-flight reports are dropped silently; the partially
written state region is left as-is on disk (publication
files persist on tmpfs).

**Recovery.** Reload inputfs (`kldload inputfs.ko`).
Module re-attaches all HID devices, recreates the
publication regions (truncating the existing files), and
resumes.

## drawfs

### EFI framebuffer init fails (no preload metadata)

**Trigger.** drawfs loads on a system that did not pass
EFI framebuffer information through to the kernel
(missing `efi_fb` preload, BIOS boot, or unusual loader
config).

**Signal.**
```
drawfs: EFI framebuffer init failed
drawfs: DRM init failed, falling back to swap
```

**Response.** drawfs loads with no display backend.
Surface composition still works in software; surfaces
are kept in vm_objects but never blitted to a physical
display. semadraw can still run and process SDCS
streams; no pixels reach a screen.

**Recovery.** Boot via the FreeBSD EFI loader with EFI
framebuffer metadata, or load a working DRM driver
before drawfs. Reload drawfs after the change.

### sysctl hw.drawfs.efifb.* unavailable

**Trigger.** Same as above (or drawfs not loaded at
all). Consumers that read these sysctls (notably inputfs
at MOD_LOAD via Stage D.2) cannot get geometry.

**Signal.** Consumer-side log lines naming the missing
sysctl.

**Response.** Each consumer falls back to its own
default. inputfs uses 1024x768 and leaves
`transform_active = 0` (see "drawfs not loaded at
inputfs MOD_LOAD" above).

**Recovery.** Same as above.

## semadraw

### Client disconnects mid-frame

**Trigger.** A SDCS client's IPC socket closes (process
exit, network drop on remote transport, explicit
`client.disconnect`).

**Signal.**
```
client <id> disconnected
client_disconnected event emitted
```

**Response.** The compositor surface registry releases
the client's surface allocations after a deferred
free (the registry borrowed slices into the client's
`sdcs_buffer`; freeing the borrow before the registry
finishes a render pass would cause use-after-free, which
the deferred-free path prevents). Compositor heartbeats
(`frame_complete`) continue across the disconnect.

**Recovery.** Self-handled. The client may reconnect
with a new session.

### Compositor cannot open `/dev/draw`

**Trigger.** drawfs kernel module is not loaded when
semadrawd starts.

**Signal.** rc.d's `semadrawd_prestart` precondition
check fires:
```
/dev/draw is not present; is the drawfs kernel module loaded?
```
and `service semadrawd start` exits non-zero before
launching the daemon.

**Response.** semadrawd does not start. The system
stays in its previous state; no half-running compositor.

**Recovery.** `kldload drawfs`, then
`service semadrawd start`.

### Surface count exceeds compositor limit

**Trigger.** A pathological client (or many cooperating
clients) creates surfaces faster than they are reaped.

**Signal.** Compositor logs a per-client surface limit
warning when the soft cap is approached, errors when
the hard cap is reached.

**Response.** New surface-create requests get rejected
with an error code; existing surfaces continue to
render. The misbehaving client is not killed, but its
new requests fail until it reaps.

**Recovery.** Reap surfaces in the offending client.
The cap is configurable via
`hw.drawfs.max_surfaces` for global limits.

## semasound and audiofs

### audiofs module absent at broker startup

**Trigger.** semasound starts (boot or restart) before the
audiofs module is loaded, and the run script's defensive
`kldload audiofs` also fails (module missing from
/boot/modules, or a kernel mismatch).

**Signal.** The broker's open of `/dev/audiofs0` fails and it
exits; s6-log records it under
`/var/log/utf/semasound/current`, and the AD-20 finish script
applies flap protection if the failure persists.

**Response.** Posture 2 per
`AWASE_DAEMON_DEPENDENCY_ABSENCE.md`: exit cleanly, let
supervision retry. The clock is unaffected in either
direction (the kernel writes it; a dead broker stops mixing,
not time).

**Recovery.** `sudo sh install.sh` redeploys the module and
restarts the stack; for a transient case,
`service audiofs start` then `service semasound start`.

### Broker killed or exits

**Trigger.** Crash, `kill`, or operator stop outside the
service verbs.

**Signal.** "semasound: signal received, shutting down" on a
signal-driven exit (the socket is unlinked in the handler,
ADR 0028); on any death, `publish_ts` on the state surfaces
goes stale, which is the designed liveness signal (no
tombstone is written).

**Response.** s6 respawns the broker; its run script
re-asserts the module guard. Clients see their connection
drop and reconnect; per-target election re-runs on the next
session opener.

**Recovery.** None usually needed beyond the respawn.
Persistent crash loops engage the AD-20 flap protection;
diagnose from the s6-log.

### Status verb run unprivileged misreports supervision

**Trigger.** `service semasound status` (or any Awase shim's
status/stop verb) run without sudo. `supervise/` is
root-owned mode 0700, so `s6-svok` fails with EACCES, which
is indistinguishable from absence by exit code.

**Signal.** Shims generated by current install.sh print
"supervise state unreadable (mode 0700); run with sudo";
older shims printed the misleading "not under supervision".

**Response.** Cosmetic; supervision state is unaffected.

**Recovery.** Rerun with sudo. (This mode cost a diagnosis
cycle during F.6 closure on a perfectly healthy boot.)

### Maintenance tooling fights supervision

**Trigger.** Bench or maintenance work pkills the broker or
unloads the module while the service is up. s6 respawns the
broker within seconds and its run script reloads the
installed module, racing whatever the tooling was doing
(observed during F.6 closure as a bench_setup kldload
failure: "module already loaded or in kernel").

**Signal.** The respawned broker's startup lines in s6-log;
uptime arithmetic in `service utf-supervisor status` shows
the restart; the tooling's module load fails.

**Response.** Working as designed from supervision's side;
the defect is in tooling that predates the supervised
resting state.

**Recovery.** Follow the takeover protocol (ADR 0030
Decision 4): `s6-svc -dwd -T 5000 /var/service/utf/semasound`
before claiming the machine, `s6-svc -u` to hand it back.
Tooling must implement this, not bare pkill.

## Generic operational

### tmpfs at /var/run fills up

**Trigger.** Some other process on the system fills
`/var/run` (Awase's publication files are a few KB to
~70 KB each, well below the size that would cause this
on a typical tmpfs).

**Signal.** Awase processes that try to create or extend
files under `/var/run/sema/` log ENOSPC errors per the
inputfs vn_open mode above.

**Response.** Affected publishers fall back to in-memory
operation (kernel side: kthread skips file syncs;
userspace side: createFile returns ENOSPC and the
publisher exits with an error). Already-open files are
unaffected.

**Recovery.** Free space on `/var/run`, then reload the
affected modules and restart the affected daemons.

### Multiple inputfs instances loaded

**Trigger.** Operator loads inputfs twice, possibly
with different paths or configurations.

**Signal.** kldload reports the second load as
"module already loaded"; no second instance is created.

**Response.** Only the first-loaded inputfs is active.
The second load is a no-op.

**Recovery.** Not applicable; the situation does not
arise. inputfs is a singleton kernel module by
construction.

## Notes

This catalog grew out of an audit of actual log strings,
fallback paths, and recovery code in each substrate. It
is meant as a living document: when a new failure mode is
handled in code, it should land here in the same commit
or a follow-up. Modes that are documented but lack
handling code are acceptable as a "known issue" entry but
should be tagged as such; the catalog should not promise
behaviour the code does not deliver.

The structure deliberately avoids prescribing operator
runbooks beyond the immediate recovery step. Specific
operational procedures (escalation, alerting thresholds,
maintenance windows) belong to the operator, not to Awase.

Related documents:

- `docs/Thoughts.md`: the temporal-substrate framing,
  including drift handling and the three graphics
  strategies.
- `docs/AWASE_ARCHITECTURAL_DISCIPLINE.md`: the
  replace/accept/remove discipline that informs which
  failure modes Awase chooses to handle versus delegate
  to the platform.
- `inputfs/docs/adr/0013-publication-permissions.md`:
  the threat model that informs the permission-denied
  failure mode for unauthorized consumers.
