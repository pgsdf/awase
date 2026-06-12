# FreeBSD Code Improvements Identified Through UTF Development

This document catalogs concrete issues in FreeBSD's legacy code that UTF
development has uncovered, and records where UTF's design or implementation
represents a measurable improvement over the existing approach. It is a
companion to `docs/FREEBSD_SUBSYSTEMS.md`, which records the disposition of
each FreeBSD subsystem under UTF's architectural discipline. This document
records the findings; that document records the resulting structural choice.

## Why this document exists

UTF's primary goal is architectural coherence, not reliability or
performance per se. Coherence means that every component in the guarantee
path is either owned by UTF or explicitly accepted as a named dependency.
Pursuing that goal forces close reading of the FreeBSD code UTF interacts
with, and that reading has, repeatedly, surfaced concrete defects, missing
abstractions, and silent failure modes in the legacy stack.

The findings here are not a critique of FreeBSD as a whole. They are a
record of specific places where UTF had to do something different because
the existing code could not be used as found. Each entry names the issue,
the location in the FreeBSD tree where it lives, the UTF context in which
it was discovered, and the improvement UTF's design represents. Several of
the entries are realistic candidates for upstream patches against
`subr_bus.c`, the HID stack, or the vt(4) console.

## Catalog conventions

Each entry uses the following structure:

* **Issue.** One-sentence statement of the defect or missing abstraction.
* **Location.** Files or subsystems in the FreeBSD tree where the issue lives.
* **Discovery context.** The UTF work that surfaced it.
* **UTF improvement.** What UTF does differently and why that is better.
* **Upstream candidate.** Whether the improvement is plausibly a FreeBSD
  patch, a UTF-internal architectural choice, or both.

The catalog is grouped by FreeBSD subsystem.

---

## NewBus

### NB-1: No re-probe on driver registration

**Issue.** When a new `DRIVER_MODULE` registers against a bus whose children
have already been claimed by other drivers, NewBus does nothing. The new
driver waits for device-attach events that may never arrive. A higher probe
priority does not displace an attached incumbent. The failure mode is silent.

**Location.** `sys/kern/subr_bus.c`, specifically the `DRIVER_MODULE` and
`devclass_driver_added` paths.

**Discovery context.** The inputfs Stage B.2 work. `kldload inputfs` ran
after `hms`, `hkbd`, and `hmt` had already claimed every hidbus child.
inputfs registered cleanly, logged its module-load message, and then
attached nothing. No error was reported anywhere. Recovery required a
manual sequence of `devctl detach` on each populated child followed by
`devctl rescan` on each populated bus instance, applied across `hidbus0`
through `hidbus6`.

**UTF improvement.** UTF documents the manual recovery sequence in
`inputfs/docs/STAGING.md` and ships a script that performs it correctly
across all bus instances rather than just the first one. The architectural
fix, however, is a kernel change: a `BUS_REPROBE_CHILDREN` callback fired
automatically when `DRIVER_MODULE` registers against an existing bus, with
each existing child re-evaluated against the now-larger driver set. The
right-of-incumbent question (does a higher-priority newcomer evict the
attached driver?) is policy and should be a kernel knob, defaulting to no.
Silently doing nothing is the worst possible default.

**Upstream candidate.** Yes. A focused patch against `subr_bus.c` adding
the callback would be welcome upstream and would benefit every loadable
driver, not only UTF.

### NB-2: Probe priority constants are coarse and underdocumented

**Issue.** The probe priority constants (`BUS_PROBE_VENDOR`,
`BUS_PROBE_DEFAULT`, `BUS_PROBE_GENERIC`, `BUS_PROBE_LOW_PRIORITY`, and a
handful of others) are coarse, their semantic ordering is not documented
in any single place, and the rules for when a vendor-specific driver
should outrank a generic one are stated only in folklore.

**Location.** `sys/sys/bus.h` defines the constants. No consolidated
documentation exists in the manual pages.

**Discovery context.** Deciding what probe priority inputfs should return
during ADR 0007. The answer turned out to depend on whether inputfs was
considered vendor-specific (it is not), generic (it competes with hms,
hkbd, and hmt for the same TLCs), or something else. The folklore answer
("return BUS_PROBE_DEFAULT and arrange for the other drivers not to be
loaded") is unsatisfying.

**UTF improvement.** UTF's docs/FREEBSD_SUBSYSTEMS.md names the drivers it
displaces explicitly rather than relying on probe-priority arithmetic.
This is more legible than a numeric tiebreaker and survives kernel-version
changes that might renumber the constants.

**Upstream candidate.** Documentation patch only. A consolidated table in
`bus.9` would be useful.

### NB-3: Diagnostic surface for failed probes is thin

**Issue.** When a driver does not bind, there is no straightforward way to
ask the kernel why. `devinfo -rv` shows current state but not history.
`dmesg` shows attach lines but not failed probes unless the driver itself
logs them. No FreeBSD equivalent of Linux's `/sys/bus/*/drivers_probe`
exists.

**Location.** `sys/kern/subr_bus.c`, `usr.sbin/devctl`, `sbin/devinfo`.

**Discovery context.** Multiple sessions of inputfs debugging, the
GhostBSD netdriver bootstrap work, and the early xconfig sessions all hit
the same wall: a driver that should have attached did not, and no
mechanism existed to retrieve the reason.

**UTF improvement.** UTF logs every probe and attach event from its own
modules at `kern.devctl` verbosity, which is a partial workaround for its
own drivers but does nothing for incumbents. The architectural fix is a
`kern.devctl.probe_log` ring buffer in the kernel, capturing the last N
probe attempts with driver, child, returned priority, and outcome.

**Upstream candidate.** Yes. A bounded ring buffer accessible via sysctl
or a new devctl verb is a small, self-contained patch.

### NB-4: `devctl rescan` and `devctl reprobe` are easy to confuse

**Issue.** The verbs `devctl rescan`, `devctl detach`, and `devctl attach`
have distinct semantics, but the failure modes when the wrong one is used
are silent no-ops. A script that calls `rescan` on a bus when it needed
`attach` on an orphaned child produces no error.

**Location.** `usr.sbin/devctl`, `sys/kern/subr_bus.c`.

**Discovery context.** The first inputfs recovery script ran `devctl
rescan hidbus1` and reported success, while the actual mice and keyboards
were spread across `hidbus0` through `hidbus6`. The script logged that it
had completed its work. Nothing had been re-probed.

**UTF improvement.** UTF's recovery script enumerates every bus instance
under `devinfo` and operates on each. The clearer kernel-side fix is a
triplet of verbs with explicit logging at configurable verbosity:
`devctl rescan-bus`, `devctl reprobe-device`, `devctl evict-and-reprobe`,
each of which logs what it actually did.

**Upstream candidate.** Yes. Userland-only change to devctl, plus a small
kernel logging hook.

### NB-5: `MODULE_PNP_INFO` auto-load is a foot-gun for downstream distributions

**Issue.** `linker.hints` plus `MODULE_PNP_INFO` causes drivers in
`/boot/kernel/` to auto-load during bus enumeration, before userland or
rc.d gets a chance to influence anything. For a stock FreeBSD this is
correct. For a distribution like PGSD that wants inputfs to be the sole
HID consumer, it is a constant battle: anything that puts `hms.ko` back
on disk wins by default.

**Location.** `sys/kern/kern_linker.c`, the `MODULE_PNP_INFO` macro
expansion in `sys/sys/module.h`.

**Discovery context.** Repeated regressions during GhostBSD package
updates that reinstalled `hms.ko` and `hkbd.ko` into `/boot/kernel/`,
causing inputfs to lose its claim on devices it had previously attached.

**UTF improvement.** UTF documents the conflict in
`docs/FREEBSD_SUBSYSTEMS.md` and ships a pkg-lock entry that prevents the
relevant base packages from being reinstalled in PGSD. The cleaner fix is
a per-driver opt-in: a `MODULE_PNP_INFO_OPT_IN` variant or a per-driver
`loader.conf` policy of "load only if explicitly requested" would let
downstream distributions express their intent without rebuilding base
system packages.

**Upstream candidate.** Partial. The opt-in macro is a small change; the
policy question of how distributions express driver exclusions is larger.

---

## HID stack and input

### HID-1: Legacy ukbd and ums drivers shadow the modern stack in the source tree

**Issue.** `sys/dev/usb/input/ukbd.c` and `sys/dev/usb/input/ums.c` still
exist in the FreeBSD tree and look authoritative, but on FreeBSD 13 and
later they are effectively replaced by the modern HID stack
(`uhub -> usbhid -> hidbus -> hms/hkbd/hgame/hcons/hsctrl/utouch/hpen`).
A new driver designed against the legacy files compiles cleanly and then
attaches nothing on the target system.

**Location.** `sys/dev/usb/input/` is the legacy path; `sys/dev/hid/` and
`sys/dev/usb/input/usbhid.c` are the modern stack.

**Discovery context.** ADR 0006, the original inputfs USB driver design.
The ADR was built by reading `ukbd.c` and `ums.c`, both of which are
present in the source tree and look like the right reference. Live
investigation via `kldstat` and `devinfo` revealed that neither was loaded
on the target system. ADR 0006 was superseded by ADR 0007, which
re-architected inputfs to attach at hidbus with HID Top-Level Collection
matching instead of USB interface class matching.

**UTF improvement.** UTF maintains `docs/FREEBSD_SUBSYSTEMS.md`, which
records the disposition (Replace, Accept, Remove) of each FreeBSD
subsystem against the loaded state of the system, not the source tree.
The discipline is: check `kldstat` before designing.

**Upstream candidate.** Documentation patch. A `DEPRECATED` notice in
`ukbd.4` and `ums.4` pointing readers to the modern stack would prevent
others from making the same mistake.

### HID-2: Detaching hms during a live session is unrecoverable

**Issue.** Detaching `hms` during a live desktop session leaves the system
in an unrecoverable mouse state at the userland level, even when kernel
state is correctly restored. The detach contract does not account for
userland state coherence.

**Location.** `sys/dev/hid/hms.c`, specifically the detach path and its
interaction with `devd` and `moused`.

**Discovery context.** Stage B.2 verification on the live host. `kldload
inputfs` after detaching `hms` left the mouse cursor frozen at the
userland layer even though inputfs had successfully claimed the device
and was producing events on the kernel side. A GhostBSD VM was
provisioned for subsequent testing because the live machine could not be
recovered without rebooting.

**UTF improvement.** UTF owns the full path from device to event consumer
rather than hot-swapping underneath running userland. semainput, drawfs's
input injection path, and semadrawd are designed as a single coherent
stack. When that stack is in control, it does not need to negotiate with
moused or devd for ownership of the mouse.

**Upstream candidate.** No. The fix is architectural and belongs in UTF,
not in FreeBSD's existing per-driver detach paths.

### HID-3: evdev is a Linux compatibility layer carrying Linux semantics into FreeBSD

**Issue.** FreeBSD's evdev implementation faithfully reproduces Linux
semantics: `EVIOCGRAB`, `/dev/input/eventN`, `struct input_event`, key
codes from `linux/input-event-codes.h` (so `KEY_A=30`). It exists to let
libinput and Xorg run unmodified on FreeBSD, which is a legitimate goal,
but it carries Linux vocabulary into a system that otherwise speaks BSD.
Crucially, evdev has no awareness of any clock other than
`CLOCK_MONOTONIC`.

**Location.** `sys/dev/evdev/`, `sys/compat/linux/linux_input.h`.

**Discovery context.** semainput's `identity_snapshot` had to reproduce
the Linux `KEY_*` numbering verbatim to interoperate with evdev. The
chronofs work then revealed the deeper problem: evdev's timestamps come
from `CLOCK_MONOTONIC`, not from the audio sample position that the rest
of UTF uses as its master clock.

**UTF improvement.** UTF's long-term direction is to replace evdev with a
native FreeBSD input path. The intermediate step, already in place, is
semainput's audio-clock timestamping: events are stamped with the audio
sample position at the moment they enter UTF's event path, so that
downstream consumers (semadrawd, semadraw-term) see a clock consistent
with the rest of the system. The full replacement runs through the
inputfs kernel module and bypasses evdev entirely for the devices UTF
claims.

**Upstream candidate.** No. Replacing evdev is a UTF-internal goal and
would not be welcome upstream because the FreeBSD project values Linux
input-stack compatibility.

### HID-4: `hid_start_parse` kindset accepts only one item-kind bit

**Issue.** `hid_start_parse(d, kindset, id)` accepts a `kindset` argument
that is documented as a bitmask of item kinds, but it actually requires
exactly one bit to be set. Passing a multi-bit kindset compiles cleanly,
runs without error, and produces incorrect parse results.

**Location.** `sys/dev/hid/hid.c`, the `hid_start_parse` implementation
and the `usbhid(9)` manual page.

**Discovery context.** ADR 0008's implementation plan for the HID report
descriptor walk specified a three-bit combined kindset
(`HID_INPUT | HID_OUTPUT | HID_FEATURE`). The code compiled, loaded, and
returned zero items. Reading `hid_start_parse` source revealed the
single-bit requirement; the ADR was corrected with an Errata section, and
the parse loop was rewritten to call `hid_start_parse` three times, once
per item kind.

**UTF improvement.** UTF's ADR 0008 records the corrected pattern. The
fix in the FreeBSD code is a documentation update on `usbhid(9)` and
ideally a `KASSERT` in `hid_start_parse` that catches the multi-bit case
in debug kernels.

**Upstream candidate.** Yes. Both the manual page clarification and the
debug-kernel `KASSERT` are small, self-contained patches.

---

## vt(4) console

### VT-1: `kbdcontrol -k /dev/null` returns EINVAL under vt(4)

**Issue.** The documented mechanism for detaching the keyboard from the
console (`kbdcontrol -k /dev/null`) returns `EINVAL` ("Inappropriate
ioctl for device") under vt(4). The ioctl was supported under the older
syscons driver but was not carried over.

**Location.** `sys/dev/vt/vt_core.c`, the `kbdctl` ioctl handler.

**Discovery context.** Attempting to give semainput exclusive keyboard
access by detaching the keyboard from vt(4). The documented command
failed with no useful diagnostic. The working alternative turned out to
be `EVIOCGRAB` on the evdev devices, which is undocumented as a vt(4)
interaction.

**UTF improvement.** semainput uses `EVIOCGRAB` to obtain exclusive
access on the devices it cares about. The long-term improvement, on the
UTF side, is to replace vt(4) on the input side as drawfs already does on
the display side.

**Upstream candidate.** Documentation patch on `kbdcontrol(1)` and
`vt(4)`. The ioctl could also be reimplemented under vt(4) to match the
documented behavior, though by now the documentation should probably
catch up to the implementation rather than the other way around.

### VT-2: `kern.vt.kbd_halt`, `kern.vt.kbd_poweroff`, `kern.vt.kbd_reboot` intercept keys even when another consumer grabs

**Issue.** Even when a userland process holds `EVIOCGRAB` on a keyboard
device, vt(4) continues to intercept the documented halt, poweroff, and
reboot key combinations unless the corresponding `kern.vt.kbd_*` sysctls
are explicitly disabled. The grab is not honored for these key paths.

**Location.** `sys/dev/vt/vt_core.c`, the key-event handling that
short-circuits to the system control paths.

**Discovery context.** semainput had grabbed the keyboard via
`EVIOCGRAB`, but accidental presses of Ctrl-Alt-Del still rebooted the
machine. The fix required disabling three sysctls at semadrawd startup
and restoring them at shutdown.

**UTF improvement (historical).** The pre-AD-20 start.sh launcher
disabled the three sysctls on launch and restored them on `--stop`;
that launcher was removed under F.6 (ADR 0029) with the supervised
lifecycle replacing it. The cleaner fix on the FreeBSD side remains
unchanged: honor the grab: if a userland process holds `EVIOCGRAB`,
vt(4) should not intercept any key from that device.

**Upstream candidate.** Yes. A small change to vt(4)'s key dispatch that
checks for an outstanding grab before applying the halt and reboot
shortcuts.

### VT-3: vt(4) and efifb are coupled at the kernel-config level

**Issue.** Removing `device vt` from the kernel config to free the
console for a replacement also removes `device efifb`, because efifb is
in practice always built and loaded alongside vt. Userland code that
needs the EFI framebuffer parameters cannot get them from a system
configured without vt unless it goes directly to the boot metadata.

**Location.** `sys/conf/files`, `sys/dev/efifb/`, `sys/dev/vt/hw/efifb/`.

**Discovery context.** The drawfs self-containment audit. drawfs needed
to confirm it could be the sole console consumer on a kernel built
without vt or efifb. The audit script categorized every symbol drawfs
references as STABLE (kernel core), VT_DEP, EFIFB_DEP, or UNKNOWN.

**UTF improvement.** drawfs discovers the EFI framebuffer via
`preload_search_info(MODINFOMD_EFI_FB)`, mapping the framebuffer through
the EFI runtime services and `pmap_mapdev_attr`. None of its symbols are
VT_DEP or EFIFB_DEP, which means drawfs runs cleanly on a kernel built
without either device. The audit script is preserved at
`drawfs/scripts/drawfs-fb-audit.sh` as a regression guard.

**Upstream candidate.** Partial. The decoupling itself is reasonable
upstream, but most users want both devices present. A `device efifb`
that can be built without `device vt` is the modest version of the
change; the larger architectural question (whether the console should be
a single coupled subsystem or a set of independent ones) is more
contentious.

---

## Cross-cutting observations

Several themes recur across the entries above. They are worth naming
because each is more general than any single defect.

* **Steady state is fine; transitions fail.** Most of the issues above
  occur when something changes: a driver is loaded after the bus has been
  populated, a device is detached during a live session, a sysctl changes
  while a consumer holds a grab, a kernel-config line is removed. The
  legacy code is well-tested for the case where everything is set up
  correctly at boot and then left alone.

* **Silent failures dominate.** Every transition-time defect above
  produces no error message by default. The probe does not happen, the
  detach leaves stale userland state, the wrong devctl verb succeeds
  with no effect. Adding diagnostic surface (NB-3) would help debug
  several of the others.

* **The source tree is not the running system.** ukbd and ums still
  exist in `sys/dev/usb/input/`. They are not loaded. A new driver
  designed against them compiles cleanly and attaches nothing. The
  discipline of checking `kldstat` before reading source is more reliable
  than reading source first.

* **Linux compatibility layers are not native abstractions.** evdev and
  the `linuxulator` paths are useful for running existing software, but
  they encode assumptions ("monotonic clock," "Linux key codes") that
  pin downstream consumers to Linux semantics. A FreeBSD-native input
  path is a different artifact, not a refinement of the evdev one.

* **Coherence is the goal, not reliability.** UTF accepts that its
  approach is sometimes less performant or less feature-rich than the
  legacy stack it replaces. The trade-off is that every component in
  UTF's guarantee path is either owned by UTF or named as an accepted
  dependency. The findings above are the cost of paying close enough
  attention to the legacy stack to maintain that property.

## Maintenance

This document is appended to, not rewritten, when new findings emerge.
Each entry should cite a discovery context that is concrete and a
location in the FreeBSD tree that is specific enough to find with a
single `grep`. Entries that are speculative or aesthetic do not belong
here; they belong in the relevant ADR.

When a finding leads to a UTF code change, the ADR that records the
change should cite the entry here. When a finding leads to an upstream
patch, the patch URL or PR number should be added to the entry.
