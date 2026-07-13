# 0001 drawfs takes the framebuffer at boot

## Status

Proposed (2026-05-15).

This is drawfs's first ADR file. drawfs has previously tracked
architectural decisions in `docs/DECISIONS.md` (a numbered list of
short statements) and in `docs/DESIGN.md` plus its siblings. The
size and stakes of AD-10 warrant a fuller ADR in the style of
`semadraw/docs/adr/` and `inputfs/docs/adr/`. Future drawfs ADRs
follow this same shape.

Tracks BACKLOG.md AD-10 ("drawfs negotiates framebuffer ownership
with vt(4)"). Supersedes the cooperative-VT-switching framing
that was AD-10's original direction; the current framing is the
Option Y rescope recorded in `docs/sessions/2026-05-10.md` and in
BACKLOG.md AD-10 lines 2560-2589.

Sub-stages outlined below; this ADR is AD-10.1. AD-10.2 through
AD-10.4 are implementation; AD-10.5 (keystroke handover via
kbdmux bridge) closed independently 2026-05-09 under
`inputfs/docs/adr/0019-kbdmux-bridge.md`.

## Context

### Two display drivers, one framebuffer

On UEFI-booted FreeBSD systems, the EFI loader hands a graphics
framebuffer to the kernel through the `MODINFOMD_EFI_FB` preload
metadata block (`sys/boot/efi/`). Two consumers in the current
PGSD kernel claim that framebuffer:

  1. **`vt_efifb`**, the framebuffer backend for the `vt(4)`
     terminal console. `vt(4)` is FreeBSD's default kernel console
     driver; `vt_efifb` is its UEFI framebuffer backend
     (`sys/dev/vt/hw/efifb/efifb.c`). `vt_efifb` attaches during
     SI_SUB_DRIVERS at boot, maps the framebuffer via
     `pmap_mapdev_attr` with write-combining attributes, and
     drives kernel console output to it for `dmesg`, daemon
     startup messages, panic traces, and `getty`/`login` prompts.

  2. **drawfs's `drawfs_efifb` backend**
     (`drawfs/sys/dev/drawfs/drawfs_efifb.c`). drawfs maps the
     same `MODINFOMD_EFI_FB` framebuffer using the same
     `pmap_mapdev_attr` technique, exposes it via the
     `DRAWFSGIOC_GET_EFIFB_INFO` and `DRAWFSGIOC_BLIT_TO_EFIFB`
     ioctls, and lets `semadrawd`'s drawfs backend blit rendered
     UTF surface frames directly to the framebuffer on each
     `SURFACE_PRESENT`. This is how drawfs supersedes `vt_efifb`
     as the display primitive (per `drawfs/docs/ROADMAP.md`
     lines 50-61).

Both drivers map the same physical address range with the same
attributes. Both believe they own the framebuffer. Neither
performs any handshake or coordination with the other. The
kernel does not prevent or detect this; `pmap_mapdev_attr` is
happy to create multiple mappings of the same physical pages.

### The current operational symptom

Verified on `pgsd-bare-metal-test-machine` 2026-05-02 during the
first end-to-end Phase 1 bench: kernel log messages flash across
the screen behind the UTF surface during normal operation.
`vt(4)`'s console output (boot messages, `dmesg` entries written
post-boot, daemon startup logs) overwrites pixels that semadrawd
just blitted, and vice versa. The visible effect is a strobe of
amber `semadraw-term` glyphs alternating with white kernel
console text in the same display region.

Typing into `semadraw-term` is functional in the sense that
keystrokes reach the right destination (the kbdmux bridge per
ADR 0019 keeps `vt(4)` and inputfs both keystroke-supplied), but
the display is visually corrupted whenever the kernel writes to
the console.

`sudo conscontrol mute on` silences kernel console output for
the duration of the boot session, which eliminates the visible
flashing without disturbing either driver. This workaround is
documented in `INSTALL.md` Hazard 7 and is the recommended
mitigation until AD-10 lands. It is **operator-driven and
per-boot**: every fresh boot starts with `vt(4)` drawing again
until `conscontrol mute on` is run.

### Why this is not a quick fix

The root cause is not a bug in either driver. Both drivers do
what they were designed to do. The bug is the absence of an
ownership protocol between them.

X11 servers solve the analogous problem with the FreeBSD-specific
`VT_GETMODE` / `VT_SETMODE` ioctl pair: an X server places a VT
into `VT_PROCESS` mode, registers itself as the owner, and
exchanges `VT_RELDISP` acknowledgements with the kernel when the
user initiates a VT-switch (Ctrl-Alt-Fn). Wayland compositors do
the same. The kernel mediates handoffs; neither side draws to
the framebuffer except when it holds the VT.

UTF needs the same mediation, but at the drawfs layer rather
than per-client, since drawfs is the framebuffer owner from the
kernel's perspective and semadraw clients (term, hello,
pgsd-sessiond) all draw through drawfs. A per-client VT
handshake would require every UTF client to be a VT-aware
process, which contradicts the design where userland clients
issue protocol commands and drawfs/semadrawd handle the hardware.

### The original design: cooperative runtime VT switching

AD-10's original framing (pre-2026-05-10) was a cooperative VT
switch performed in drawfs at runtime. The lifecycle:

  - System boots. `vt_efifb` attaches in the normal driver
    sweep, draws kernel console output to the framebuffer.
  - User starts a UTF session (logs in via `getty`, runs
    `semadrawd`, runs `pgsd-sessiond` or another semadraw client).
  - drawfs registers itself with the kernel as a VT owner via
    `VT_SETMODE` in `VT_PROCESS` mode. The kernel suspends
    `vt(4)` console output to the framebuffer.
  - drawfs unmaps the console framebuffer mapping (or signals
    `vt_efifb` to drop its mapping; the mechanism varies by
    implementation).
  - UTF session runs uninterrupted. Kernel messages go to
    `dmesg` ring buffer only; no console output to framebuffer.
  - User exits the UTF session. drawfs releases ownership via
    `VT_SETMODE` and `VT_RELDISP`. Kernel restores `vt(4)` to
    the framebuffer.
  - On UTF-side crash or panic, the kernel detects the VT owner
    is gone and restores `vt(4)`. This is the safety net that
    prevents a crashed UTF stack from leaving the system with
    no working display.

This design was correct when `vt(4)` and UTF were expected to
coexist indefinitely and the bench reality was "log in via the
existing console, then start UTF on demand." Implementing it
involves writing the `VT_PROCESS`-mode handler in drawfs's
device-attach path, the `VT_RELDISP` ack path in drawfs's
runtime, the unmap/remap dance in `drawfs_efifb`, and the
panic-recovery path. Estimated medium effort, well-trodden
ground.

### Option Y: drawfs owns the framebuffer at boot

Recorded 2026-05-10 in `docs/sessions/2026-05-10.md`. PGSD's
direction is to run a UTF-native graphical login daemon
(`pgsd-sessiond`, SM-1) at boot. There is no normal-boot path
through `getty`/`login` to a console; the user boots directly
into the UTF graphical login. The only time `vt(4)` matters is
when the operator boots single-user mode (`boot -s` from the
loader prompt) for system recovery.

This changes the design space substantially.

If `vt(4)` never owns the framebuffer in the normal boot path,
the cooperative-runtime handshake is solving a problem that
doesn't exist. The simpler model is: `vt_efifb` is configured
out of normal-boot attachment, drawfs takes the framebuffer
from kernel attach onward, and the recovery path (boot to
single-user mode) takes `vt(4)` instead of drawfs.

This is "Option Y" in the BACKLOG. The decision matrix that
landed it:

| concern | cooperative runtime | boot-time takeover |
|---|---|---|
| primary boot UX | login at vt console first | direct to UTF login |
| `vt(4)` runtime presence | always | normal path: not attached. recovery: attached. |
| code surface in drawfs | `VT_SETMODE` + `VT_RELDISP` + unmap dance | mode-selection logic + early-attach ordering |
| recovery if UTF stack crashes | kernel restores `vt(4)` automatically | operator reboots to single-user mode |
| keystroke handoff | needed anyway (ADR 0019 kbdmux bridge) | needed anyway for recovery-mode console |
| boot speed | slower (vt attaches, then UTF takes over) | faster (drawfs takes once) |
| matches "Option Y" PGSD distribution intent | partial | fully |

Boot-time takeover wins on every axis except "vt(4) always
attached." Vic's 2026-05-10 decision: take that loss.

### Why this is structural

Two paths to "drawfs takes the framebuffer at boot":

  - **Path A: a kernel-config decision.** Build PGSD's kernel
    `WITHOUT vt_efifb`. The `vt(4)` console driver remains, but
    its EFI framebuffer backend is excluded at compile time. On
    single-user boot, `vt(4)` falls back to a serial console
    only (no framebuffer). drawfs's efifb backend attaches
    normally and owns the framebuffer unconditionally.

  - **Path B: a loader.conf tunable plus early-attach ordering.**
    Stock GENERIC kernel with `vt_efifb` compiled in. The
    operator (or the PGSD installer) sets
    `hw.syscons.disable=1` in `/boot/loader.conf`, which
    disables `vt_efifb` attachment at boot (despite the
    misleading legacy name, this tunable controls vt's
    framebuffer backend, not the sc(4) console). drawfs's
    `drawfs_efifb` module is loaded in `/boot/loader.conf`
    (`drawfs_load="YES"`) and attaches normally. On
    single-user recovery, the operator unsets the tunable from
    the loader prompt and `vt_efifb` attaches.

Path A produces a kernel that can never run a working `vt(4)`
framebuffer console. Recovery requires serial access. This is
intolerable for a development bench and arguably for production
too: a single misconfigured boot can leave a machine
unreachable to anyone without a serial cable. We reject Path A
for that reason.

Path B keeps both options reachable: normal boot has drawfs
own the framebuffer; recovery boot (toggle the tunable at the
loader prompt) has `vt(4)` own it. The mechanism is standard
FreeBSD configuration, well-known to operators (Linux i915kms
and amdgpu use a similar idiom on UEFI hardware), and reverses
cleanly. We choose Path B.

## Decision

drawfs takes the framebuffer at boot via Path B:

  - PGSD systems set `hw.syscons.disable=1` in
    `/boot/loader.conf` to disable `vt_efifb` from attaching
    in the normal boot path.

  - PGSD systems load `drawfs.ko` early in the boot sequence
    via `drawfs_load="YES"` in `/boot/loader.conf`, ensuring
    drawfs's efifb backend is registered before any other
    consumer of `MODINFOMD_EFI_FB`.

  - drawfs's `drawfs_efifb_attach` path remains as it is today:
    read the EFI framebuffer metadata, map with
    `VM_MEMATTR_WRITE_COMBINING`, expose via the
    `DRAWFSGIOC_*` ioctls. No `VT_SETMODE`/`VT_RELDISP` work
    is added; drawfs is the only consumer in the normal path.

  - `vt(4)` remains compiled into the kernel for recovery:
    boot to single-user mode (`boot -s` from the loader prompt)
    with `hw.syscons.disable=0` unset (or set explicitly to 0
    at the loader prompt) restores `vt_efifb` attachment.

  - `pgsd-sessiond` (SM-1) is the first userspace consumer of
    the framebuffer at boot. Stage 9 boot integration wires
    `semadrawd` and `pgsd-sessiond` into the rc.d or s6
    supervision tree to start before any login prompt.

  - The cooperative VT handshake described in the original
    AD-10 framing is **not implemented**. If a future
    PGSD system needs runtime VT switching (e.g. to support a
    legacy X server alongside UTF), this ADR is superseded
    rather than amended; the cooperative-runtime design is
    preserved in this ADR's Context section as the alternative
    not taken.

### What is in scope for AD-10

  - Documenting the boot-time-takeover model (this ADR).
  - Verifying that `hw.syscons.disable=1` + `drawfs_load="YES"`
    produces the intended boot state on `pgsd-bare-metal`.
  - Documenting the recovery procedure (boot to single-user
    with `hw.syscons.disable=0`).
  - Installer support: `install.sh` and any package-postinstall
    hooks add the required entries to `/boot/loader.conf` (with
    a backup of the prior version so the operator can revert).

### What is out of scope for AD-10

  - Cooperative runtime VT switching (rejected; see above).
  - Recovery via serial console (orthogonal; PGSD systems may
    have serial consoles, but AD-10 does not require them).
  - DRM/KMS framebuffer ownership (separate concern; drawfs's
    `drawfs_drm` backend has its own boot-attachment design,
    out of scope for AD-10's efifb-only focus).
  - Multi-monitor framebuffer ownership (single primary
    framebuffer assumed; multi-monitor support is a separate
    design problem).
  - `getty(8)` on additional ttys (ttyv1..ttyv7) (orthogonal;
    these continue to attach to `vt(4)` and provide text
    consoles unrelated to the EFI framebuffer).

## Implementation

### AD-10.1: this ADR (Proposed)

Document the design decision and the alternative not taken.
Lift the BACKLOG context into a durable design record. No code.

### AD-10.2: installer support for the tunable

The PGSD installer or `install.sh` adds two lines to
`/boot/loader.conf`:

```
# PGSD: drawfs takes the EFI framebuffer (AD-10).
# Disables vt_efifb attachment in the normal boot path. To
# recover via vt(4) text console, boot to single-user mode and
# set hw.syscons.disable=0 at the loader prompt before
# continuing.
hw.syscons.disable="1"
drawfs_load="YES"
```

The installer backs up the prior `/boot/loader.conf` to
`/boot/loader.conf.bak-<timestamp>` so the change is reversible
without an external recovery medium.

Bench: install on a clean `pgsd-bare-metal` clone, reboot,
verify that `dmesg` does not show `vt_efifb` attaching and that
`/dev/drawfs` is present.

### AD-10.3: bench verification of the normal boot path

After AD-10.2, the normal boot sequence is:

  1. UEFI loader hands off to FreeBSD loader.
  2. Loader processes `loader.conf`: sees
     `hw.syscons.disable=1` set as a kenv tunable, loads
     `drawfs.ko` as a preload module.
  3. Kernel boots. SI_SUB_DRIVERS attaches drivers. `vt_efifb`'s
     attach probes `hw.syscons.disable`; when set, returns
     without claiming the framebuffer. drawfs's efifb backend
     attaches normally and maps `MODINFOMD_EFI_FB`.
  4. rc.d starts. semadrawd starts (via Stage 9 service
     definition). pgsd-sessiond starts (Stage 9 too).
  5. pgsd-sessiond connects to semadrawd, queries output info,
     creates a fullscreen surface. Login UI appears.

Verification: clean install + reboot. Observable signals:

  - `dmesg | grep -E "vt_efifb|drawfs"` shows drawfs efifb
    attaching, no `vt_efifb` attachment line.
  - `ls /dev/drawfs` exists.
  - Console output (`dmesg -a` from another process, panic
    traces) does not flash on the framebuffer; the only
    pixels drawn are by drawfs clients.
  - The user sees pgsd-sessiond's login UI from the moment the
    kernel finishes early-boot output.

Expected gap during early boot: between loader handoff and
drawfs efifb attach, there are a few hundred milliseconds where
no driver is drawing. The framebuffer's prior contents (the
loader's menu or boot splash) persist on screen until drawfs
overwrites them. This is normal and matches `vt_efifb`'s own
behavior; no work required.

### AD-10.4: bench verification of the recovery path

To recover a system where pgsd-sessiond will not start (broken
PAM config, broken `.session` file, broken semadrawd, etc.):

  1. Power-cycle the machine.
  2. At the FreeBSD loader prompt (the menu shown after the
     UEFI handoff), press Escape to drop to the loader command
     line.
  3. `set hw.syscons.disable=0` to override the loader.conf
     setting for this boot.
  4. `boot -s` to single-user mode.
  5. Kernel boots. `vt_efifb` attaches normally (the tunable
     was overridden). Single-user shell appears on the
     framebuffer text console.
  6. Operator fixes the broken configuration.
  7. `exit` to continue to multi-user, or `reboot` to start
     fresh.

Verification: deliberately break `/etc/pam.d/pgsd-sessiond` on
a freshly-installed PGSD system, reboot. Verify that
pgsd-sessiond fails to start (this is acceptable). Then perform
the recovery sequence above and verify that step 5 produces a
working text console.

This recovery path is the only reason `vt(4)` and `vt_efifb`
remain compiled into the kernel. The PGSD distribution does not
plan to ever build a kernel without them.

### AD-10.5: keystroke handover (CLOSED)

This sub-stage closed independently on 2026-05-09. See
`inputfs/docs/adr/0019-kbdmux-bridge.md` for the design and
BACKLOG.md AD-10.5 entry for the closure log. The bridge is
default-on as of step 8 of ADR 0019's implementation outline;
console login at ttyv0 works through inputfs->kbdmux->vt(4).

The recovery path described in AD-10.4 depends on AD-10.5
being in place: single-user mode needs keyboard input to
ttyv0, which the kbdmux bridge supplies. AD-10.5 closing is a
prerequisite for AD-10.4 being meaningful.

## Risks and mitigations

### Risk: black-screen failure mode

Worst case: drawfs fails to attach (e.g. `drawfs.ko` corrupt or
ABI-mismatched after a kernel update), and `vt_efifb` is
disabled by the tunable. Neither driver owns the framebuffer.
The display shows the loader's last contents indefinitely. No
text appears.

The system continues to boot and is reachable via SSH (assuming
`sshd` starts and the network attaches), but there is no
display output.

**Mitigation 1: the recovery path is documented and operator-known.**
Boot to single-user mode with `set hw.syscons.disable=0` at the
loader prompt. This always works because the loader's own UI is
not affected by either driver; it runs before the kernel attaches
anything.

**Mitigation 2: PGSD systems should have working SSH access for
remote recovery.** The installer enables sshd by default. An
operator with SSH access can fix a broken drawfs.ko without
physical access.

**Mitigation 3: do not enable AD-10's tunables on a system
without one of the recovery paths.** The installer should
detect whether the system has serial console access or working
sshd before applying the tunables; if neither, defer the
tunable change until the operator confirms recovery is
arranged.

### Risk: hw.syscons.disable tunable semantics drift across FreeBSD versions

`hw.syscons.disable` is a FreeBSD tunable whose name dates from
the sc(4) console era (pre-vt(4)). Its current semantics
(disable `vt_efifb` attach) are a result of vt(4) replacing
sc(4) and inheriting some of the same tunables. A future
FreeBSD release could rename or repurpose this tunable.

**Mitigation: pin PGSD to a known-good FreeBSD release.**
PGSD's `pgsd-kernel-build.sh` already does this; the kernel
version is controlled. Tunable-name changes would surface as a
boot test failure on the next kernel rebuild, caught before
release.

**Mitigation: document the alternative.** If
`hw.syscons.disable` stops working, the alternative is a
kernel-config change (Path A above) or a small drawfs-side
patch that registers a higher-priority attach for the
framebuffer. Both are bigger changes than a tunable; AD-10 may
need an amendment if either becomes necessary.

### Risk: drawfs efifb attach race against vt_efifb

If for some reason both drivers do attempt to attach (e.g. the
tunable is set but the operator forgot to load `drawfs.ko`, or
vice versa), the SI_SUB_DRIVERS attach order determines who
wins. Currently drawfs's efifb backend has no explicit
SI_ORDER, defaulting to SI_ORDER_MIDDLE. `vt_efifb` also
defaults to middle. The race is non-deterministic.

**Mitigation: set drawfs's efifb backend to SI_ORDER_FIRST.**
This is a one-line change in `drawfs/sys/dev/drawfs/drawfs_efifb.c`'s
SYSINIT registration. Done as part of AD-10.2's bench work;
not a code change with downstream consequences.

**Mitigation: emit a kernel log warning if drawfs detects
`vt_efifb` is also attaching.** drawfs can check the
`vt_efifb` driver presence via `devclass_find` in its attach
and log a warning. Helpful for catching misconfigurations.

### Risk: recovery procedure forgotten or undocumented

If the recovery procedure (AD-10.4) is not documented where
operators can find it, a broken pgsd-sessiond becomes a
bricked machine until someone remembers `boot -s`.

**Mitigation:** `INSTALL.md` must include the recovery
procedure prominently, not buried. The installer's terminal
output after applying the tunables must print a one-line
reminder: "To recover, boot to single-user mode and set
hw.syscons.disable=0 at the loader prompt."

### Risk: graphical glitches at the loader-to-kernel handoff

There is a brief window where the loader has handed off
control but the kernel has not yet attached drawfs. The
framebuffer's prior contents (loader menu, boot splash) remain
on screen. If this window is unusually long, the user sees a
stale image, then a brief black flicker, then pgsd-sessiond's
login screen.

This is cosmetic and matches what stock FreeBSD does with
`vt_efifb`. No mitigation required; documenting that this is
expected behaviour suffices.

## Consequences

### What this enables

  - **Stage 9 boot integration**. pgsd-sessiond can become the
    boot-time login provider per its bounded responsibility
    (ADR 0001 §Logout). semadrawd has uncontested framebuffer
    access from kernel attach onward.
  - **Eliminating the `conscontrol mute on` workaround**.
    INSTALL.md Hazard 7 can move from "operator workaround" to
    "historical context" once AD-10.2 lands.
  - **A single, deterministic display path**. drawfs owns the
    framebuffer; semadrawd consumes drawfs; UTF clients
    consume semadrawd. No flashes, no races, no per-boot setup.
  - **A clean separation between normal and recovery boots**.
    Operators have a well-defined procedure for recovering a
    broken system; the recovery path uses standard FreeBSD
    mechanisms.

### What this forecloses

  - **Runtime VT switching between UTF and `vt(4)`.** Operators
    who want to flip back and forth between a UTF session and a
    text console during a single boot session cannot do so. They
    must reboot to switch. This is acceptable for PGSD's target
    use case (the iMac is a dedicated graphical workstation),
    but would be a hard sell on a general-purpose FreeBSD
    server.
  - **Cooperative coexistence with X11 servers** on the same
    framebuffer. If a future PGSD user wanted to run an X11
    server alongside UTF (e.g. for legacy applications), the X11
    server would need to share the framebuffer with drawfs, not
    `vt(4)`. drawfs would need its own equivalent of
    `VT_SETMODE` (or the X11 server would need to be a UTF
    client). This is a separate design problem that this ADR
    does not address.

### What this defers

  - **DRM/KMS framebuffer ownership**. drawfs's `drawfs_drm`
    backend (`drawfs/sys/dev/drawfs/drawfs_drm.c`) targets
    DRM/KMS-capable GPUs (i915, amdgpu, etc.) rather than the
    EFI framebuffer. Its boot-attachment story is different
    and is tracked separately. AD-10 is efifb-only.
  - **Multi-monitor support**. EFI provides one primary
    framebuffer. Multi-monitor displays need a different
    mechanism (DRM/KMS connector enumeration or similar).
    Out of scope.
  - **vt(4) retirement (AD-11)**. Long-term, PGSD's roadmap
    contemplates removing `vt(4)` entirely once UTF can
    provide its own console for recovery (a UTF-native
    single-user-mode shell). AD-11 supersedes AD-10's
    Path-B-with-recovery model. Not in scope here.

## Open questions

These are deliberately not decided in this ADR; they surface
during AD-10.2-.4 implementation:

  1. **Does `hw.syscons.disable=1` need to be paired with
     `kern.vty="vt"` or another tunable for completeness?**
     The 2026-05-02 bench experiment used `conscontrol mute on`
     and did not test the loader.conf tunable. AD-10.2's first
     bench should confirm the tunable alone is sufficient.

  2. **What happens to `getty` on additional ttys (ttyv1-ttyv7)
     when `vt_efifb` is disabled?** Those gettys still want to
     attach to virtual terminals; the question is whether
     vt(4) without an efifb backend still creates them, or
     whether they fail. If they fail, AD-10.2's installer
     should disable them in `/etc/ttys` to prevent boot-time
     errors. Investigate during AD-10.2 bench.

  3. **Does `acpiconf -s 3` (suspend) work correctly when
     drawfs owns the framebuffer?** Suspend/resume on FreeBSD
     historically required `vt_efifb` to participate in the
     ACPI dance. drawfs's efifb backend has no suspend/resume
     hooks today. AD-10.4 should test that
     pgsd-sessiond's Stage 8 Suspend action actually works
     end-to-end on a system with these tunables set. If
     suspend produces a hung display on resume, AD-10 may need
     suspend/resume hooks in drawfs (a sub-stage AD-10.6, to be
     written if needed).

  4. **Will the EFI loader's menu still be visible** before the
     kernel attaches drawfs? The loader writes to the
     framebuffer via UEFI's GOP before any FreeBSD driver
     attaches. Disabling `vt_efifb` should not affect the
     loader's UI. Confirm during AD-10.2's first bench.

  5. **Does drawfs's panic handler need to release the
     framebuffer** so a panic dump becomes visible? Currently
     drawfs has no panic hook. Without one, a kernel panic
     while drawfs owns the framebuffer leaves the panic trace
     unseen (it goes to `dmesg`, but the screen continues
     showing the last UTF surface). This is a real operational
     concern. Possibly a sub-stage AD-10.7. Not blocking for
     AD-10.2-.4, but worth noting.

## References

  - `BACKLOG.md` AD-10 entry (lines 2555-2740 of the
    2026-05-15 BACKLOG snapshot). Original problem framing and
    sub-stage outline.
  - `BACKLOG.md` AD-10.5 entry (now closed). Keystroke handover.
  - `docs/sessions/2026-05-10.md`. Option Y decision record.
  - `inputfs/docs/adr/0019-kbdmux-bridge.md`. AD-10.5 design
    and implementation log.
  - `pgsd-sessiond/docs/adr/0001-design.md` §Logout (lines
    320-325) and §Stage 9 (lines 498-503). Boot integration
    requirements that AD-10 unblocks.
  - `semadraw/docs/adr/0006-multi-user-refactor.md` (AD-31).
    Already done; provides the multi-user semadrawd needed for
    Stage 9 alongside AD-10.
  - `drawfs/sys/dev/drawfs/drawfs_efifb.c`. The driver this
    ADR concerns.
  - `sys/dev/vt/hw/efifb/efifb.c` (FreeBSD tree). The
    counterpart driver this ADR displaces in the normal boot
    path.

---

## Amendment (2026-07-13): drawfs is compiled into the kernel

**Accepted. Ratified 2026-07-13 (operator). Implemented.**

Path B is superseded. drawfs becomes a compiled-in device
(`device drawfs` in the kernel config), not a preloaded module.

### Why the original decision no longer holds

Path B rested on three things, and all three are now false:

1. **"PGSD systems set `hw.syscons.disable=1` to stop `vt_efifb`
   attaching."** AD-39 removed `vt`, `vt_efifb`, `sc` and `vga` from the
   kernel entirely, because vt(4) and drawfs were both writing the same
   physical framebuffer address (0xc0180000) and vt's repaints were
   overwriting drawfs's cursor sprites. There is nothing left to
   disable.

2. **"`vt(4)` remains compiled into the kernel for recovery."** AD-39
   removed it. That recovery path does not exist.

3. **"PGSD systems load `drawfs.ko` early via `drawfs_load="YES"` in
   `/boot/loader.conf`."** This is the one that broke, and it broke on
   metal (campaign finding F14). `pgsd-loader` does not read
   `/boot/loader.conf`. It builds a module chain containing exactly one
   entry, the kernel. On an armed boot drawfs is simply never loaded,
   nothing owns the framebuffer, and nothing draws: a blank screen on a
   kernel that is otherwise running correctly.

### The decision, and the principle behind it

**Match what you replace.** drawfs replaces `vt` and `vt_efifb`. Those
are not modules and cannot be: there is no `sys/modules/vt` and no
`sys/modules/vt_efifb`. They are declared `device vt` / `device
vt_efifb` and compiled in conditionally (`sys/conf/files`:
`dev/vt/vt_core.c optional vt`). drawfs should be the same.

The reason FreeBSD does it that way is the reason we should: **the
framebuffer owner is a bootstrap dependency.** It must exist before
anything can claim the framebuffer. A module loaded later is a module
that races, and that race is precisely what AD-39 was written to
prevent. Compiling drawfs in eliminates the race by construction rather
than by ordering.

It also removes drawfs's dependency on the loader entirely, which is
what makes the armed boot path work.

### What does NOT change, and why the principle is not a rule of thumb

The same principle gives a different answer for inputfs and audiofs, and
that is the sign it is a real principle:

  - **inputfs stays a module.** It replaces `hkbd`, `ukbd`, `hms` and
    the rest of the AD-8 HID set, which ARE modules
    (`sys/modules/hid/hkbd`, `sys/modules/usb/ukbd`). More decisively,
    inputfs MUST NOT be preloaded: install.sh records that "the state
    kthread panics when loaded before /var/run is mounted", so it is
    kldloaded by an rc.d service after root mounts. Compiling it in
    would break it.

  - **audiofs stays a module.** It replaces `sound` and `snd_hda`, which
    are modules (`sys/modules/sound/driver/hda`). It is likewise not
    preloaded: its rc.d service carries `REQUIRE: FILESYSTEMS`.

Neither is a bootstrap dependency. Both can arrive after root, and both
must. Only the framebuffer owner has to exist before anything else can
touch what it owns.

Consequence for the armed boot path: with drawfs compiled in, inputfs
and audiofs load normally from rc.d once root is mounted, and they never
needed the loader at all. drawfs was the single point of failure and it
is the one the principle says to compile in anyway.

### Consequences

  - `drawfs_load="YES"` is removed from `/boot/loader.conf`. install.sh
    stops writing it.
  - The PGSD kernel config gains `device drawfs`, and `sys/conf/files`
    gains `dev/drawfs/drawfs.c optional drawfs` and its siblings.
    drawfs's sources already live at `drawfs/sys/dev/drawfs/`, the
    in-tree layout, so this is a build-plumbing change rather than a
    port.
  - drawfs can no longer be `kldunload`ed. This is accepted: there is no
    case for unloading the framebuffer owner on a running system, and
    the modularity was only ever a deployment mechanism, not a runtime
    capability.
  - The kernel image grows by drawfs. It is a display driver on a
    machine whose purpose is display; this is not a cost worth avoiding.
  - `pgsd-loader` still cannot load modules. That remains true and
    remains a real gap (a loader that cannot load modules is a
    kernel-jumper), but it is no longer on the critical path, because
    nothing on the boot path needs preloading any more.

### Bench requirement

The PGSD kernel, booted by pgsd-loader with no module preloading of any
kind, comes up with drawfs owning the framebuffer, inputfs and audiofs
loaded from rc.d, and pgsd-sessiond drawing the login.

### Implementation note: /usr/src stays pristine

The obvious way to compile drawfs in would be to copy its sources into
/usr/src/sys/dev/drawfs/ and add them to sys/conf/files. That was
rejected: it makes /usr/src dirty, the AD-57 pin check treats a dirty
tree as not-the-pinned-source and fails the build, and it would revert
the out-of-tree module work done 2026-07-12 which exists precisely to
keep /usr/src a faithful checkout.

config(8) has a supported escape. A files-list entry marked `local` is
emitted with no $S/ prefix (usr.sbin/config/mkmakefile.cc:552 sets
filetype = LOCAL on the keyword, and :591-592 sets f_srcprefix = "" for
it), so its path is used exactly as written. pgsd-kernel/files.drawfs
therefore names drawfs's sources by absolute path in the Awase repo, and
the kernel compiles them straight out of it.

The config references the list with `files "files.drawfs"`, which
config(8) supports (config.y: FILES ID SEMICOLON { newfile($2); }) and
which sys/arm/conf/GENERIC uses the same way.

Result: drawfs is in the kernel, /usr/src is never written to, and the
pin holds.
