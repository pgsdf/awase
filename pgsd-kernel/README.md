# PGSD kernel

This directory holds the FreeBSD kernel configuration for PGSD, the
distribution this project ships. PGSD's kernel is a self-contained
config (a derivative of FreeBSD GENERIC at the time of PGSD's
creation, kept in sync by re-merging when tracking new FreeBSD
releases) that removes the HID class drivers competing with
`inputfs` for ownership of HID devices and suppresses their
modules from the build.

## Quick start

From the repo root on the bench:

```
sudo install -m 0644 pgsd-kernel/PGSD /usr/src/sys/amd64/conf/PGSD
sh pgsd-kernel/pgsd-kernel-build.sh check
sudo sh pgsd-kernel/pgsd-kernel-build.sh build --clean
sudo sh pgsd-kernel/pgsd-kernel-build.sh install
sudo shutdown -r now
```

The first command verifies the build environment (read-only,
always safe). The second runs `make buildkernel` with the
correct `WITHOUT_MODULES` argument: 30-60 minutes for a clean
build, seconds for incremental rebuilds (drop `--clean` after
the first run). The third runs `make installkernel` and verifies
the AD-8 closure (no suppressed `.ko` files left on disk to
auto-load at boot). The fourth reboots into the new kernel.

For `PGSD-DEBUG`, pass the kernconf name to each phase:

```
sudo sh pgsd-kernel/pgsd-kernel-build.sh build --clean PGSD-DEBUG
sudo sh pgsd-kernel/pgsd-kernel-build.sh install PGSD-DEBUG
```

The rest of this document explains what each step does, the
reasons for the `WITHOUT_MODULES` discipline (see "Why this
kernel exists" below), the install variations on pkgbase versus
source-built systems, and how to recover if a build or boot
goes wrong. Skim it on a first read; come back to specific
sections when you hit a failure mode.

## Files

- `PGSD`: kernel configuration. Self-contained; read it.
- `PGSD-DEBUG`: debug variant. Includes `PGSD` and adds the
  WITNESS / INVARIANTS / DDB / DEADLKRES options block. Use
  this kernconf during development of kernel-side PGSD
  components (drawfs, inputfs, AD-28's planned
  `inputfs_kbdmux` bridge). The build procedure is the same
  as for PGSD with one substitution; see "Building a debug
  kernel" below.

## Why this kernel exists

`inputfs` (see `inputfs/` and ADRs under `inputfs/docs/adr/`) is the
PGSDF kernel input substrate. It attaches to `hidbus` and consumes
HID reports directly. FreeBSD's stock GENERIC kernel statically
compiles two keyboard drivers that prevent `inputfs` from owning
USB keyboards: `hkbd` (the modern HID keyboard driver, claiming
hidbus children) and `ukbd` (the legacy USB keyboard driver,
claiming USB devices directly before `hidbus` sees them). The
PGSD config simply omits these device lines.

Removing the device line from the kernel image is necessary but
not sufficient. The FreeBSD build still produces `.ko` files for
these drivers under `/boot/kernel/` from the modules tree, and
the kernel registers their PNP signatures in `linker.hints`. At
boot, when the kernel sees a USB keyboard or mouse, it
auto-loads the matching `.ko` and the system returns to the
contested state.

The closure for the modules build is `WITHOUT_MODULES=...`
passed on the **command line** to `make buildkernel` and
`make installkernel`. With that argument, nothing for those
drivers appears under `/boot/kernel/`, `linker.hints` has no
PNP entries to match, and auto-load is impossible.

A `makeoptions WITHOUT_MODULES=...` directive in the kernel
config file would seem like the right place to put this, but it
does **not** reliably suppress the modules. The kernel-config
`makeoptions` reaches the kernel-link step, but the modules
tree is invoked from `/usr/src/Makefile.inc1` via a separate
make that does not always inherit those options. We tried this
during AD-8 development and the modules built anyway. The
command-line argument is the supported and reliable path; the
PGSD config file therefore does not declare
`WITHOUT_MODULES` to avoid presenting a false sense of closure.

The `WITHOUT_MODULES` list documented in the build procedure
below covers the wider set of HID class drivers ADR 0007
enumerates as competitors (`hms`, `hgame`, `hcons`, `hsctrl`,
`hpen`, `hmt`, `hconf`, and the `hidmap`
HID-to-evdev framework). Most of those are not in stock
GENERIC at the time of writing; their inclusion in the list is
anticipatory, documenting that PGSD excludes them regardless of
whether they appear in a future GENERIC or arrive as a loadable
module.

`hidbus`, `usbhid`, and the generic `hid` layer remain. `inputfs`
needs all three.

`evdev`, `uinput`, and `EVDEV_SUPPORT` are out of scope for this
config and remain enabled. Removing the evdev userland contract
is a separate architectural decision with broader consequences
during the PGSD transition; tracked separately, not folded into
AD-8.

## Relationship to upstream GENERIC

PGSD copies GENERIC's body verbatim aside from the AD-8 changes
(file header, ident, and the removed `device hkbd` / `device ukbd`
lines). The file header notes this. When tracking a new FreeBSD
release, re-merge PGSD against the new GENERIC: diff the two
configs, apply non-AD-8 upstream changes to PGSD, leave the AD-8
changes in place. This is a small enough surface that the cost
of manual re-merge is acceptable; the alternative (`include
GENERIC` plus `nodevice` overrides) was insufficient because
`nodevice` does not affect the modules build.

The modules-build closure (`WITHOUT_MODULES`) lives in the build
command line rather than the config, so it does not enter into
this re-merge calculation. See "Why this kernel exists" above.

## Build

Requires the FreeBSD source tree at `/usr/src` matching the running
release. If you do not have it, install via `git` from
`https://git.freebsd.org/src.git` or via `pkg install src`.

From the repository root:

```
sudo install -m 0644 pgsd-kernel/PGSD /usr/src/sys/amd64/conf/PGSD
cd /usr/src
sudo make buildkernel KERNCONF=PGSD \
    WITHOUT_MODULES="hkbd ukbd hms hgame hcons hsctrl hpen hmt hconf hidmap"
```

The `WITHOUT_MODULES` argument is the build-time mechanism that
keeps the listed `.ko` files from being produced. It must be on
the command line — see "Why this kernel exists" above for why
the corresponding `makeoptions` directive in a kernel config
does not work.

The build takes 30-60 minutes on modern hardware. The kernel
config does not require a full `buildworld` since the only change
is which kernel modules are compiled; the userland is unchanged.

## Install

Modern FreeBSD 15 systems are typically installed via pkgbase, which
turns the kernel into a managed package (`FreeBSD-kernel-generic`).
Plain `make installkernel` refuses to run on such a system to avoid
clobbering files owned by the pkg database. There are two install
paths depending on whether your system is pkgbase-managed.

Determine which you have:

```
pkg which /boot/kernel/kernel
```

If that returns `was installed by package FreeBSD-kernel-...`, you
are on a pkgbase system. Otherwise, the kernel was installed from
source and the classic path applies.

### pkgbase-managed system (typical for FreeBSD 15)

Unregister the pkgbase kernel so `pkg(8)` stops tracking it, then
install over the now-untracked files. Pass `WITHOUT_MODULES` to
`make installkernel` as well as to `make buildkernel`; the install
step walks the modules tree and would otherwise re-install any
`.ko` files it could find from a prior build.

```
sudo pkg unregister FreeBSD-kernel-generic
cd /usr/src
sudo make installkernel KERNCONF=PGSD DESTDIR=/ \
    WITHOUT_MODULES="hkbd ukbd hms hgame hcons hsctrl hpen hmt hconf hidmap"
```

`pkg unregister` removes the package's database entry without
touching the files in `/boot/kernel/`. `make installkernel
DESTDIR=/` then overwrites the kernel with the PGSD build, moving
the previous kernel to `/boot/kernel.old/`.

This sequence comes from the FreeBSD forums thread "FreeBSD 15:
now, kernel is a package" (Feb 2026). Building a custom pkgbase
kernel package (the alternative) is not yet supported in the way
that would make pkg(8) happy with it; the unregister-then-install
path is the recommended workaround.

Note for the future: a subsequent `pkg upgrade` may try to
reinstall `FreeBSD-kernel-generic` and overwrite the custom
kernel. To prevent this, `pkg-lock(8)` the kernel or arrange a
PGSD-specific pkg repository. Out of scope for B.5 verification;
relevant once PGSD has its own pkg infrastructure.

### Source-built system (classic path)

```
cd /usr/src
sudo make installkernel KERNCONF=PGSD \
    WITHOUT_MODULES="hkbd ukbd hms hgame hcons hsctrl hpen hmt hconf hidmap"
```

This installs the new kernel to `/boot/kernel/` and moves the
previous kernel to `/boot/kernel.old/`.

### Reboot

```
sudo shutdown -r now
```

The previous kernel remains bootable from the loader menu via
"Boot Options" -> "Boot Single User" or by explicitly selecting
`kernel.old`.

## Verify the kernel installed correctly

After reboot, confirm the running kernel is PGSD:

```
sysctl kern.conftxt | head -3
```

The `ident` line should read `ident PGSD` (not `ident GENERIC`).

Confirm the static kernel does not include the competing drivers:

```
config -x /boot/kernel/kernel | grep -E "^device[[:space:]]+(hkbd|ukbd)"
```

This should return no lines. `hkbd` and `ukbd` are the keyboard
drivers in stock GENERIC at the time of this config; their absence
from the static kernel is the first half of unblocking inputfs.

Confirm the modules also do not exist on disk (the second half;
`WITHOUT_MODULES` should have suppressed these from the build):

```
ls /boot/kernel/ | grep -E "^(hkbd|ukbd|hms|hgame|hcons|hsctrl|hpen|hmt|hconf|hidmap)\.ko"
```

This should return no lines. If any of these `.ko` files exist,
`WITHOUT_MODULES` did not take effect during the kernel build
and the runtime auto-load contention path is still open.
Investigate the build log; if the build was a `make installkernel`
without a fresh `make buildkernel`, the install may have copied
old modules from a prior build. A clean `make buildkernel
KERNCONF=PGSD` followed by `make installkernel KERNCONF=PGSD`
should produce the expected result.

Cross-check that `linker.hints` does not advertise PNP signatures
for the suppressed drivers:

```
strings /boot/kernel/linker.hints | grep -E "(hkbd|ukbd|hms|hgame|hcons|hsctrl|hpen|hmt|hconf|hidmap)"
```

Should return no lines. `linker.hints` is regenerated by
`kldxref` from the `.ko` files present in the directory at the
time it runs. `installkernel` runs `kldxref` automatically as
its last step, so a build that successfully suppressed the
modules produces a clean hints file in the same operation.

If the disk listing is clean but `linker.hints` still shows
entries for these drivers, the hints file is stale relative
to the directory contents — usually the result of a manual
`rm` of `.ko` files without a follow-up `kldxref`. Re-run
`sudo kldxref /boot/kernel` and re-check.

The user-visible symptom of stale hints is a stream of
"`kldload: can't load X: No such file or directory`" messages
during boot, one per autoload attempt the kernel makes against
each missing module. Functionally harmless (the load fails and
the boot continues), but indicates the cleanup is incomplete.

Confirm `hidbus`, `usbhid`, and `hid` are still present:

```
config -x /boot/kernel/kernel | grep -E "^device[[:space:]]+(hid|hidbus|usbhid)$"
```

Should return three lines.

## Building a debug kernel

For development work on kernel-side PGSD components, build the
`PGSD-DEBUG` variant instead of `PGSD`. PGSD-DEBUG inherits every
device, option, and makeoption from `PGSD` via include(5) and
adds the runtime debugging stack: WITNESS lock-order tracking,
INVARIANTS / INVARIANT_SUPPORT assertions, DDB interactive
debugger, DEADLKRES deadlock resolver, and MALLOC_DEBUG_MAXZONES
for use-after-free visibility.

The runtime cost is significant. WITNESS in particular adds
overhead to every mutex acquisition; the FreeBSD handbook quotes
5-10x slowdown on lock-heavy workloads. Use PGSD-DEBUG only on
development hardware. Do not deploy PGSD-DEBUG to systems where
performance matters.

### When to use PGSD-DEBUG

- Developing or testing kernel modules that integrate with
  base-system kernel APIs (drawfs against the framebuffer
  layer, inputfs against hidbus, AD-28's `inputfs_kbdmux`
  bridge against `kbd_register` / `kbdmux`).
- Investigating a kernel panic whose backtrace from a
  production kernel is incomplete or unhelpful.
- Verifying a locking-discipline change (per
  `docs/DF4_VERIFICATION.md`).

For routine usage of an already-stable kernel, stay on `PGSD`.

### Build procedure

Identical to the production build, with `PGSD` replaced by
`PGSD-DEBUG`. The `WITHOUT_MODULES` argument does not change;
ADR 0018 §3a's "inputfs is the exclusive HID consumer"
invariant is just as in force under PGSD-DEBUG as under PGSD.

PGSD-DEBUG `include "PGSD"`, so the production config must be
installed alongside PGSD-DEBUG in the same directory. If you
have already installed PGSD per the procedure above, this is
satisfied. Otherwise, install both files:

```
sudo install -m 0644 pgsd-kernel/PGSD       /usr/src/sys/amd64/conf/PGSD
sudo install -m 0644 pgsd-kernel/PGSD-DEBUG /usr/src/sys/amd64/conf/PGSD-DEBUG
```

Then build:

```
cd /usr/src
sudo make buildkernel KERNCONF=PGSD-DEBUG \
    WITHOUT_MODULES="hkbd ukbd hms hgame hcons hsctrl hpen hmt hconf hidmap"
```

Build time is comparable to PGSD; the debug options expand the
binary slightly but do not significantly change compile time.

### Install

PGSD-DEBUG is installed exactly like PGSD; the kernconf
filename is the only difference. On pkgbase systems (the
typical case for FreeBSD 15) the kernel package
`FreeBSD-kernel-generic` claims ownership of `/boot/kernel/`,
so `make installkernel` would fail without first unregistering
that package. The unregister step removes the package's
database entry without touching the files; the install then
overwrites them.

First-time install:

```
sudo pkg unregister FreeBSD-kernel-generic
cd /usr/src
sudo make installkernel KERNCONF=PGSD-DEBUG DESTDIR=/ \
    WITHOUT_MODULES="hkbd ukbd hms hgame hcons hsctrl hpen hmt hconf hidmap"
sudo shutdown -r now
```

If you have already installed PGSD via the production
procedure above, the package was unregistered then; running
`pkg unregister FreeBSD-kernel-generic` again will report a
"no such installed package"-class error. The error is benign
in this context — the package is gone and the install
proceeds — but it is an error, so be ready to see it and
continue rather than stopping. Future-proofing: a `pkg
upgrade` between PGSD installs may reinstall
`FreeBSD-kernel-generic`, in which case the unregister step
is needed again.

Subsequent rebuilds during a development session (e.g. after
editing `kbd.c`, `kbdmux.c`, or PGSD-DEBUG itself):

```
cd /usr/src
sudo make buildkernel KERNCONF=PGSD-DEBUG \
    WITHOUT_MODULES="hkbd ukbd hms hgame hcons hsctrl hpen hmt hconf hidmap"
sudo make installkernel KERNCONF=PGSD-DEBUG DESTDIR=/ \
    WITHOUT_MODULES="hkbd ukbd hms hgame hcons hsctrl hpen hmt hconf hidmap"
sudo shutdown -r now
```

No `pkg unregister` needed on rebuilds; once unregistered the
package stays gone. The previous kernel is moved to
`/boot/kernel.old/` automatically by `make installkernel`,
giving you a known-good fallback at the loader prompt.

A `pkg upgrade` between rebuilds may reinstall
`FreeBSD-kernel-generic` and overwrite your custom kernel with
upstream's. Avoid `pkg upgrade` while iterating on PGSD-DEBUG.
If you need to upgrade other packages, use `pkg upgrade -x
FreeBSD-kernel` to exclude the kernel-related packages from
the upgrade, or `pkg-lock(8)` the kernel explicitly. Out of
scope for this README; see PGSD's "pkgbase-managed system"
section above for the longer note on this issue.

The same install procedure works on source-built systems: the
`pkg unregister` step is a no-op on those systems (no package
is registered), and the rest is unchanged.

### Post-reboot verification

After booting the new kernel, confirm it is the debug build:

```
uname -i                          # expect: PGSD-DEBUG
sysctl debug.witness.watch        # expect: 1
sysctl debug.witness.skipspin     # expect: 1
sysctl kern.conftxt | grep -E '^options (WITNESS|INVARIANTS|DDB)$'
```

The `kern.conftxt` grep should return three lines, one for
each of `WITNESS`, `INVARIANTS`, and `DDB`. If any of these
sysctls or grep results are missing, the running kernel is
not the debug build and DDB / WITNESS findings will not be
reported.

Confirm the legacy HID drivers are still absent (the same
check as for PGSD; the omissions do not change in PGSD-DEBUG):

```
config -x /boot/kernel/kernel | grep -E "^device[[:space:]]+(hkbd|ukbd)$"
```

Should return nothing. This confirms the static kernel image
does not include the competing drivers — the first half of
inputfs's exclusive-HID-consumer invariant.

Confirm the modules are also absent on disk (the second half;
`WITHOUT_MODULES` should have suppressed these from the
build):

```
ls /boot/kernel/ | grep -E "^(hkbd|ukbd|hms|hgame|hcons|hsctrl|hpen|hmt|hconf|hidmap)\.ko"
```

Should return no lines. If any `.ko` file shows up here, the
`WITHOUT_MODULES` argument did not take effect during this
build — most likely cause is `WITHOUT_MODULES` missing from
either `make buildkernel` or `make installkernel` (it is
required on both). The runtime auto-load contention path is
open in this state: the kernel image lacks the drivers, but
when a USB keyboard probes, the loader auto-pulls the matching
`.ko` file in and inputfs loses the race for the device.

Recovery if any module is present:

```
cd /usr/src
sudo make cleankernel KERNCONF=PGSD-DEBUG
sudo make buildkernel KERNCONF=PGSD-DEBUG \
    WITHOUT_MODULES="hkbd ukbd hms hgame hcons hsctrl hpen hmt hconf hidmap"
sudo make installkernel KERNCONF=PGSD-DEBUG DESTDIR=/ \
    WITHOUT_MODULES="hkbd ukbd hms hgame hcons hsctrl hpen hmt hconf hidmap"
sudo shutdown -r now
```

Then re-run the module-file check after reboot.

Cross-check that `linker.hints` does not advertise PNP
signatures for the suppressed drivers:

```
strings /boot/kernel/linker.hints | grep -E "(hkbd|ukbd|hms|hgame|hcons|hsctrl|hpen|hmt|hconf|hidmap)"
```

Should return no lines. `linker.hints` is regenerated by
`kldxref` from the `.ko` files present in the directory at the
time it runs; `installkernel` calls `kldxref` automatically as
its last step. If the listing above is clean but
`linker.hints` still mentions these drivers, the hints file
is stale relative to the directory contents — manual `rm` of
`.ko` files without a follow-up `kldxref` is the usual cause.
Recover with:

```
sudo kldxref /boot/kernel
```

Then re-check.

Confirm the retained drivers that inputfs depends on are
still present:

```
config -x /boot/kernel/kernel | grep -E "^device[[:space:]]+(hid|hidbus|usbhid)$"
```

Should return three lines.

### Switching between PGSD and PGSD-DEBUG

The kernel name in `/boot/kernel/kernel` is whichever was
installed most recently. The previous kernel is in
`/boot/kernel.old/kernel`. If you have both PGSD and
PGSD-DEBUG installed and want to switch without rebuilding,
the cleanest path is to use `nextboot(8)` once and reboot:

```
sudo nextboot -k kernel.old
sudo shutdown -r now
```

This boots `kernel.old` once, then reverts to the default. To
make the switch permanent, copy or move the desired kernel
directory to `/boot/kernel`.

For routine switching during a development session, the
loader prompt at boot time is the most flexible:

```
3       # at the loader menu, "Escape to a loader prompt"
boot kernel.old/kernel
```

### Capturing panics

A panic on a debug kernel drops into DDB instead of halting.
At the DDB prompt:

```
db> bt              # backtrace
db> show locks      # held locks at the moment of panic
db> show alllocks   # full lock state across all CPUs
db> show witness    # WITNESS's lock-order graph
db> textdump dump   # capture a textdump for offline analysis
db> reset           # reboot
```

For panics that occur before the system has come up far
enough for SSH, a serial console is essential — there is no
way to scroll back the panic message from the local console
once the kernel halts. Configure `console="comconsole"` in
`/boot/loader.conf` and connect a serial cable from the bench
to a workstation running `cu` or `tip`.

A textdump captured with `textdump dump` is written to the
swap partition and dumped to `/var/crash/` by `savecore` on
the next successful boot. Inspect with `kgdb`:

```
kgdb /boot/kernel/kernel /var/crash/vmcore.last
```

`kgdb` resolves symbols against the unstripped kernel binary,
which PGSD-DEBUG (and PGSD; both have `DEBUG=-g`) build with
debug symbols intact.

## Recovery

If the new kernel does not boot, do not panic. At the loader menu,
press a number key for "Escape to a loader prompt", then:

```
boot kernel.old
```

This boots the previous kernel. From there, investigate the build
log (`/usr/obj/...`), correct the config, and rebuild.

If the loader menu does not appear, the FreeBSD boot path
automatically falls back to `kernel.old` after a configurable
timeout. See `loader.conf(5)`.

### Unwanted modules still present after install

If the verification step finds `.ko` files for any of the
suppressed drivers under `/boot/kernel/`, the most likely cause
is that `WITHOUT_MODULES` was not passed on the command line to
`make buildkernel` and `make installkernel` (or was passed to
only one of them). Recover without rebuilding the kernel:

```
for m in hkbd ukbd hms hgame hcons hsctrl hpen hmt hconf hidmap; do
    sudo rm -f /boot/kernel/${m}.ko /boot/kernel/${m}.ko.debug
done
sudo kldxref /boot/kernel
```

This deletes the leaked `.ko` files and rebuilds `linker.hints`
so the kernel can no longer auto-load them on PNP match.

Verify both surfaces are clean before rebooting. The disk
listing and the hints file are independent state; one can be
clean while the other is stale.

```
ls /boot/kernel/ | grep -E "^(hkbd|ukbd|hms|hgame|hcons|hsctrl|hpen|hmt|hconf|hidmap)\.ko"
strings /boot/kernel/linker.hints | grep -E "(hkbd|ukbd|hms|hgame|hcons|hsctrl|hpen|hmt|hconf|hidmap)"
```

Both should print no lines. If the `ls` is clean but the
`strings` still shows entries, run `sudo kldxref /boot/kernel`
again; the `kldxref` command writes hints based on the current
contents of the directory, so it must run *after* the rm
loop, not before. If both are clean, reboot and `kldstat`
should show none of those modules loaded.

For the next rebuild, ensure `WITHOUT_MODULES` is on the command
line for both `make buildkernel` and `make installkernel`.

### Periodic drift on a running system (the pkg-upgrade hazard)

The discipline above closes the build-time and install-time
contention paths. It does not protect against `.ko` files
reappearing later on a system that previously passed
verification. The most common cause is a `pkg upgrade` of
`FreeBSD-kernel-generic` (or one of its module-providing
sibling packages) that reinstalls the suppressed modules,
restoring `linker.hints` PNP entries and re-opening the
auto-load contention path. The original PGSD install
de-registered the package, but a subsequent install (manual
or via an automated `pkg upgrade -y` job) can restore it.

Other causes of drift include: a kernel rebuild that omitted
`WITHOUT_MODULES` from the install step; a port or local
script that calls `kldload` for one of the suppressed modules
explicitly; `freebsd-update` running on a system where the
PGSD kernel install is not under its tracked file set.

#### Detection on a running system

Symptom: any `inputfs<N>: ... attached` line is missing from
`dmesg` while the corresponding `kbdN at hkbdN`,
`hms<N>: <device>`, or `hmt<N>: <device>` line is present.
For `pgsd-bare-metal-test-machine` 2026-05-08 the bench
showed every TLC of every HID device claimed by a legacy
driver, with no `inputfs<N>: attached` lines anywhere — a
total exclusion (see BACKLOG AD-30 for the full investigation).

A direct check that does not require driving any HID device:

```
sudo kldstat | grep -iE 'hkbd|ukbd|hms|hgame|hcons|hsctrl|hpen|hmt|hconf|hidmap'
```

On a healthy PGSD or PGSD-DEBUG kernel this returns no lines.
Any output here indicates one of the legacy drivers is loaded
and is competing with inputfs at every probe event.

A second check covers modules that may not be loaded right now
but would be auto-loaded if a matching device plugged in:

```
ls /boot/kernel/ | grep -E "^(hkbd|ukbd|hms|hgame|hcons|hsctrl|hpen|hmt|hconf|hidmap)\.ko"
strings /boot/kernel/linker.hints | grep -E "(hkbd|ukbd|hms|hgame|hcons|hsctrl|hpen|hmt|hconf|hidmap)"
```

Both should return no lines. If `ls` returns lines but
`strings` does not, the hints file is stale (rare); if
`strings` returns lines but `ls` does not, modules were
removed without `kldxref` re-running (also rare). The
common case is that both surfaces agree.

A third check confirms inputfs *is* attached to actual HID
devices (the symptom this is all about):

```
sudo dmesg | grep 'inputfs.*attached'
```

Healthy systems show one line per HID TLC inputfs claimed
(typically several lines: each keyboard, each mouse, each
touchpad surface). A drifted system shows zero lines despite
inputfs being loaded — the failure mode AD-30 documents.

#### Recovery from drift

Same as the install-time recovery procedure documented under
"Unwanted modules still present after install" above. The
mechanism is identical: delete the leaked `.ko` files, run
`kldxref` to rebuild `linker.hints`, reboot to clear the
already-loaded competitors. The reason is different: the
drift recovery handles a system that previously worked and
regressed, not a system that never installed cleanly.

```
for m in hkbd ukbd hms hgame hcons hsctrl hpen hmt hconf hidmap; do
    sudo rm -f /boot/kernel/${m}.ko /boot/kernel/${m}.ko.debug
done
sudo kldxref /boot/kernel
sudo shutdown -r now
```

After reboot, re-run all three detection checks. Expect:
zero `kldstat` lines for the suppressed modules; zero `ls`
lines under `/boot/kernel/`; zero `strings` lines in
`linker.hints`; one or more `inputfs.*attached` lines per
HID TLC in dmesg.

If the recovery does not succeed, the kernel itself may be
GENERIC rather than PGSD. Check:

```
sysctl kern.conftxt | head -3
```

The `ident` line should read `ident PGSD` (or `PGSD-DEBUG`).
If it reads `GENERIC`, the running kernel is not the PGSD
kernel and the static device set includes the legacy drivers
unconditionally. In that case re-install per the procedure
above; the recovery `rm` only handles the loadable-modules
side, not the static-kernel side.

#### Operational discipline

Until PGSD has its own pkg repository (or a `pkg-lock(8)`
ruleset that pins `FreeBSD-kernel-generic` to "do not
upgrade"), drift is a hazard the operator manages by hand.
Suggested operational practice:

  - After every `pkg upgrade` (or `pkg install` of any
    kernel-related package), run the three detection
    commands above. If any return lines, run the recovery.
  - After every kernel rebuild, run the install-time
    verification per the "Verify the kernel installed
    correctly" section. The drift detection is a strict
    superset of the install-time verification; running
    either after an install confirms the install.
  - On a system that runs `pkg upgrade` from cron or
    another automation, gate the upgrade on a pre-check
    script that aborts if the PGSD kernel is in use and
    a kernel-package upgrade is staged. The shape:
    `pkg upgrade -n` (dry-run), grep for kernel-package
    upgrades, abort if found and prompt for manual
    review.

The drift hazard is documented but not fixed. AD-30 tracks
the structural fixes that would reduce the operational
exposure (probe-priority bump in inputfs, retiring the
alternative consumers via AD-10/AD-11). Until those land,
this section is the operational answer.

## Run B.5 verification

With the PGSD kernel running, run the bare-metal B.5 verification
script. From the repository root:

```
cd inputfs/test/b5
sudo sh ./b5-verify-baremetal.sh
```

The script runs four signals (mouse classifies as pointer; mouse
motion produces reports; keyboard classifies as keyboard; clean
unload). Expected behavior on the PGSD kernel:

- Precondition step "Unloading drivers that compete with inputfs"
  finds none of the competing drivers loaded (because they are
  not in the kernel and their modules are not on disk to
  auto-load). The step passes immediately with "No competing
  drivers loaded."
- Signal 2.1 produces an `inputfs0: ... attached HID mouse` line
  and a `roles=pointer` line.
- Signal 2.2 produces a stream of `report id=` lines as the mouse
  is moved.
- Signal 2.3 produces an `inputfs0: ... attached HID keyboard`
  line and a `roles=keyboard` line.
- Signal 2.4 produces `inputfs0: detached` and `inputfs: unloaded`.

Logs land in `inputfs/test/b5/b5-2.{1,2,3,4}.log` and the combined
`b5-pass2-baremetal.log`. Attach the combined log to the B.5
closeout commit message.

## Future PGSD kernel work

This config is the minimal change needed for B.5 verification and
its follow-up to close the auto-load contention path. As PGSD
takes shape, additional kernel deviations belong here:

- Additional entries in `WITHOUT_MODULES` for legacy input
  drivers if they appear in some future GENERIC (`ums`, `psm` are
  not currently relevant)
- `nodevice` and `WITHOUT_MODULES` for graphics drivers
  superseded by `drawfs` (AD-4)
- `nodevice` and `WITHOUT_MODULES` for audio drivers superseded
  by `semaaud` (AD-3)
- Additional `device` and `options` lines as PGSD's substrate
  matures

Each addition belongs in its own commit with reference to the
backlog item that drove it.

When tracking new FreeBSD releases, re-merge upstream GENERIC
into PGSD: diff `/usr/src/sys/amd64/conf/GENERIC` against
`pgsd-kernel/PGSD`, port any non-AD-8 upstream additions across,
keep the AD-8 deltas (header, ident, removed device lines)
intact. The `WITHOUT_MODULES` build-command argument does not
need re-merge attention since it is not in the config file.
Commit with the FreeBSD release identifier in the message.
