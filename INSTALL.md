# Installing Awase on a fresh FreeBSD system

This document walks through installing Awase on a clean FreeBSD 15
machine. Each step has a verification check; do not proceed until
the check passes. The hazards section at the end names the things
that have actually broken installs in the past.

The high-level shape is: install FreeBSD, provision `mac_do` so the
installer can elevate, mount `/var/run` as tmpfs, install build
dependencies, build awase userland, install awase, load kernel
modules manually (not from loader.conf), start daemons. `install.sh`
runs as a regular user and elevates privileged steps through `mdo`
itself; it is not run under `sudo`. It does not build the PGSD
kernel: that is a separate, operator-invoked step (Step 5.5, per
ADR 0002), and on GENERIC the installer detects the missing kernel
and says so.

## Prerequisites

- FreeBSD 15.1-RELEASE installed and bootable. ZFS or UFS root.
- Network access for `pkg install` and `git clone`.
- A `mac_do` rule that lets your user elevate to root (Step 0).
  `install.sh` runs as a regular user and elevates privileged
  steps through `mdo`; it is not run under `sudo`. If the rule
  is missing the installer detects it and prints the provisioning
  commands before doing any work.
- The `/usr/src` tree if you intend to build the PGSD kernel
  (see `pgsd-kernel/README.md`). Optional for first install;
  GENERIC works for staging, but the system is not runnable
  until the PGSD kernel is installed (Step 5.5).

## Step 0: Provision `mac_do` elevation

`install.sh` and the Awase tooling elevate through `mac_do` (the
`mdo` command), not `sudo`. `mac_do` is a FreeBSD MAC policy that
lets a named group act as another user; Awase uses it so the
installer can run as your regular user and elevate only the steps
that need root, never leaving root-owned files in the checkout.

Provision once, as root:

```
kldload mac_do
sysrc -f /boot/loader.conf mac_do_load=YES
sysctl security.mac.do.rules='gid=0>uid=0,gid=*,+gid=*'
echo 'security.mac.do.rules=gid=0>uid=0,gid=*,+gid=*' >> /etc/sysctl.conf
pw groupmod wheel -m <your-user>
```

Then log out and back in so the new `wheel` membership takes
effect. The `loader.conf` and `sysctl.conf` lines make the policy
and rule survive a reboot.

**Verify:**

```
mdo true && echo "mdo works"
```

If `install.sh` is started before this is in place, its elevation
preflight stops and walks you through the same commands; you do not
have to memorise them. Operators who prefer `sudo` can run the
installer with `PRIV=sudo sh install.sh`, but `mdo` is the default
and recommended path.

## Step 1 — Mount `/var/run` as tmpfs

Awase publishes shared-memory regions under `/var/run/sema/`. The
default `/var/run` on FreeBSD is on the same filesystem as `/var`,
which makes shared-memory writes more expensive and leaves stale
state files across reboots. Awase assumes tmpfs.

Add to `/etc/fstab`:

```
tmpfs /var/run tmpfs rw,mode=755 0 0
```

Activate without rebooting (as root, or `mdo mount /var/run`):

```
mount /var/run
```

`install.sh` also sets this up for you: it loads the `tmpfs`
module and mounts `/var/run` if it is not already tmpfs. Doing it
here first is still recommended so the verification below passes
before you start, but it is no longer strictly required.

**Verify:**

```
mount | grep /var/run
```

Expect a line `tmpfs on /var/run (tmpfs, ...)`. If absent, do not
proceed; awase will not work correctly on a non-tmpfs `/var/run`.

## Step 2 — Install build and runtime dependencies

Zig 0.16 or newer for the userland build, plus `gmake`/`rsync` for
the kernel modules, plus `s6` for the daemon supervision tree
(introduced in AD-20):

```
sudo pkg install -y zig git gmake rsync s6
```

`rsync` is used by `drawfs/build.sh` and `inputfs/build.sh` to
copy module sources into `/usr/src/sys/`. It is not in FreeBSD
base. Without it, both kernel-module builds fail at the install
step with `rsync: not found`.

For the interactive backend selector in step 3.5 below, also
install `bsddialog`:

```
sudo pkg install -y bsddialog
```

`bsddialog` is optional — `configure.sh` falls back to a plain
text menu if it is absent — but the dialog menu is a clearer
interface and is recommended.

If you intend to build the PGSD kernel, also install the FreeBSD
source tree:

```
sudo pkg install -y FreeBSD-src FreeBSD-src-sys
```

**Verify:**

```
zig version
which s6-svscan
```

`zig version` must report `0.16.x` or newer. Otherwise, the build will fail with errors about unrecognized syntax.
`which s6-svscan` must print `/usr/local/bin/s6-svscan`. If absent,
`install.sh` will fail at the dependency check in Step 6.

## Step 3 — Clone awase

The canonical location for the awase source tree on a deployed system
is `/usr/local/src/awase/`. This aligns with FreeBSD's `hier(7)`
convention: `/usr/local/src/` is the reserved area for source of
locally-installed third-party software, parallel to
`/usr/local/bin/` for the binaries and `/usr/local/etc/rc.d/` for
the service scripts. Cloning there makes the source easy to find
for a future operator and easy to remove (or keep) deliberately
after install.

```
sudo mkdir -p /usr/local/src
sudo chown $(id -u):$(id -g) /usr/local/src
cd /usr/local/src
git clone https://github.com/pgsdf/awase.git
cd awase
```

The clone is done as the regular operator user; `install.sh` runs
as that same user and elevates the steps that touch system
locations through `mdo`. It does not run under `sudo`, and it never
creates root-owned files inside the checkout, so the source tree
stays owned by you. There is no requirement that the source tree be
owned by root.

A developer working on awase rather than deploying it may prefer
to clone elsewhere (a home directory, a workspace folder). All
awase scripts use `SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"` to
resolve paths relative to themselves, so no script has a
hardcoded source location and any checkout location works
correctly. The `/usr/local/src/awase/` recommendation is for
deployed systems and operator discoverability, not for
developer workflow.

**Verify:**

```
ls
```

Expect to see `README.md`, `BACKLOG.md`, `install.sh`, `drawfs/`,
`inputfs/`, `audiofs/`, `semadraw/`, `semasound/`, `semainput/`,
`chronofs/`, `shared/`, `pgsd-kernel/`.

## Step 3.5 — Configure backend selection

Awase's semadraw compositor has several optional backends — Vulkan,
X11, Wayland, and bsdinput. On a fresh FreeBSD install without
the supporting ports, attempting to build any of these fails with
"unable to find dynamic system library" errors. The fix is to
record an explicit backend selection in `.config` before
building.

For a bare-metal PGSD test machine running the drawfs backend
exclusively, all four optional backends should be off:

```
sh configure.sh
```

In the dialog, leave all checkboxes unchecked and confirm.
`configure.sh` writes `.config` in the repo root with the
selections. `build.sh` and `install.sh` read `.config`
automatically.

You can also write `.config` directly without running the
interactive script:

```
cat > .config <<'EOF'
SEMADRAW_VULKAN=false
SEMADRAW_X11=false
SEMADRAW_WAYLAND=false
SEMADRAW_BSDINPUT=false
DRAWFS_DRM=false
EOF
```

To enable a backend later, install its libraries
(`vulkan-headers + vulkan-loader` for Vulkan, `libX11` for X11,
`libwayland-client` for Wayland, `libinput + libudev-devd` for
bsdinput, `drm-kmod` headers for the drawfs DRM/KMS backend),
then re-run `sh configure.sh` and toggle the relevant boxes.

**Verify:**

```
sh configure.sh --show
```

Expect to see the current configuration printed. If the file
does not exist, configure.sh tells you so; do not proceed
until `.config` is written.

## Step 4 — Build awase userland

The top-level `build.sh` builds every userland Zig subproject:
`semasound`, `chronofs`, and `semadraw`. The `semainput` subproject
no longer produces an executable (the daemon was retired
2026-05-08); only `libsemainput` remains, consumed by `semadrawd`
at build time.

```
sh build.sh
```

Run this as your regular user, not under `sudo`: the userland
build is unprivileged by design, which keeps `zig-out/` and
`.zig-cache/` owned by you and avoids the root-owned-artifact
problem that a later unprivileged rebuild would trip over.
This takes a few minutes and produces binaries under each
subproject's `zig-out/bin/`. Kernel modules are built separately
in step 5 — `build.sh` does not build kernel modules.

**Verify:**

```
ls semadraw/zig-out/bin/semadrawd
ls semasound/zig-out/bin/semasound
ls chronofs/zig-out/bin/chrono_dump
```

All three files must exist. If any are missing, the corresponding
build step failed; re-run `build.sh` and read the error output.

## Step 5 — Build the kernel modules

drawfs and inputfs are FreeBSD kernel modules, built against
`/usr/src` via per-module helper scripts. The full build sequence
runs as part of `install.sh` in step 6, so for a normal install
you can skip this step. To build the modules without installing
the rest of awase (for development iteration):

```
sudo sh drawfs/build.sh install
sudo sh drawfs/build.sh build
sudo sh drawfs/build.sh deploy
sudo sh inputfs/build.sh install
sudo sh inputfs/build.sh build
sudo sh inputfs/build.sh deploy
```

Each helper script copies sources into `/usr/src/sys/`, runs
`make`, and copies the resulting `.ko` to `/boot/modules/`.

**Verify:**

```
ls /boot/modules/drawfs.ko
ls /boot/modules/inputfs.ko
```

Both must exist after the deploy step.

The standalone Zig build under `inputfs/` (just `zig build` in
that directory) only builds `inputdump`, the userland diagnostic
CLI — not the kernel module. The kernel module is built by
`inputfs/build.sh` exclusively.

## Step 5.5 — Build the PGSD kernel (recommended)

The stock GENERIC kernel works for first install and basic Awase
testing, but several in-tree drivers compete with Awase for
ownership of hardware:

- `hkbd`, `ukbd`, `hms`, `hmt`, `hgame`, `hcons`, `hsctrl`,
  `utouch`, `hpen`, `hidmap`: HID class drivers that claim
  USB keyboards, mice, and touchpads before `inputfs` can.
  Without the PGSD kernel, input under Awase may not work
  (Hazard 2 below).
- `vt`, `vt_efifb`, `sc`, `vga`, `splash`: in-tree console
  drivers that write to the EFI framebuffer in parallel with
  drawfs, causing cursor sprites and other compositor output
  to be overwritten by console repaints (Hazard 7 below).

The PGSD kernel removes all of these. For full Awase behaviour
including reliable input and contention-free framebuffer
rendering, build and install PGSD.

If you do not need input or visible cursor tracking on this
install (for example, you are bringing up Awase on a remote bench
that you will only access over SSH for kernel-module testing),
you can skip this step and stay on GENERIC.

**Not built by `install.sh` (ADR 0002).** The installer detects the
kernel state and informs; it never builds or installs a kernel. On
GENERIC, a non-interactive run (`--yes`) fails fast (exit 3) unless
`--skip-kernel` acknowledges a staged, not yet runnable install; an
interactive run completes the userland deploy and prints a prominent
notice pointing here. The kernel lifecycle belongs to
`pgsd-kernel-build.sh`, operator-invoked, phase by phase; see
`pgsd-kernel/KERNEL-RECIPE.md`.

**Ordering.** Run the kernel `install` phase only after Step 6 has
deployed the userland: the kernel's AD-8 closure check refuses to
install until `/boot/modules/drawfs.ko` is on disk (a PGSD kernel
booting with no drawfs.ko comes up dark). The `check` phase and the
30-60 minute `build` phase can run at any time before that.

**Quickstart.** The kernel steps, in the working order around
Step 6:

```
sh pgsd-kernel/pgsd-kernel-build.sh check
mdo sh pgsd-kernel/pgsd-kernel-build.sh build --clean
sh install.sh                                # Step 6 (deploys drawfs.ko)
mdo sh pgsd-kernel/pgsd-kernel-build.sh install
mdo shutdown -r now
```

The default config is `PGSD`; pass `PGSD-DEBUG` as the phase argument
to build the debug variant instead.

Plan 30-60 minutes for the build. See `pgsd-kernel/README.md`
for what each step does, the pkgbase versus source-built install
variations, the PGSD-DEBUG variant for kernel-side Awase
development, and recovery procedures if a build or boot goes
wrong. Read it before running the commands if this is your
first PGSD build.

`pgsd-kernel-build.sh` is the single source of truth for source-tree
validation, AD-8 closure, recovery checks, and build flags.
`install.sh` neither sequences nor runs its phases; it only detects
whether a PGSD kernel is present and reports (ADR 0002 milestone 1).

## Step 6 — Install (system-wide)

```
sh install.sh
```

Run this as your regular user, not under `sudo`. `install.sh`
elevates the steps that need root through `mdo` itself, in two
phases: an unprivileged first phase (dependency check, the userland
build, stale-artifact cleanup) and an elevated deploy phase
(kernel modules, system files, services). Before doing any work it
runs an elevation preflight; if `mdo` is not yet provisioned it
stops and walks you through Step 0. Pass `PRIV=sudo sh install.sh`
to elevate through `sudo` instead.

This is the canonical install path. It:

1. Runs an elevation preflight, then installs missing dependencies
   (each elevated independently).
2. On a GENERIC kernel with no PGSD kernel installed for next boot,
   decides up front: non-interactive runs fail fast (exit 3) unless
   `--skip-kernel` acknowledges the staged state; interactive runs
   complete and print a notice pointing at Step 5.5.
3. Clears stale build artifacts (`clean.sh --force`) and repairs any
   root-owned `sdk/` toolchain left by an older `sudo`-based install,
   then builds the userland unprivileged.
4. Ensures `/var/run` is tmpfs (loads `tmpfs`, mounts if needed).
5. Verifies the s6 binaries are present (Step 2 dependency).
6. Builds and deploys both kernel modules (calling `drawfs/build.sh`
   and `inputfs/build.sh` for step 5's work, so step 5 is
   redundant if you run `install.sh`).
7. Copies userland binaries to `/usr/local/bin/`.
8. Generates rc.d service scripts: module loaders for `inputfs`
   and `audiofs` (the latter PROVIDEs `utf_clock`, since loading
   audiofs starts the kernel clock writer; ADR 0018/0029), the
   `utf-supervisor` (s6-svscan launcher), and thin shims for
   `semasound`, `semadraw`, and `pgsd-sessiond` that translate
   `service <name> {start,stop,status,restart}` into the matching
   `s6-svc` calls.
9. Copies the s6 service-directory layout from `s6/utf/` to
   `/var/service/utf/` (one directory per supervised daemon).
10. Creates `/var/log/utf/` and per-daemon log subdirectories
    for `s6-log` to write into.
11. Sets `drawfs_load="YES"` in `/boot/loader.conf`.
12. Sets enable flags in `/etc/rc.conf`: `inputfs_enable`,
    `utf_supervisor_enable`, plus the two daemon shims.
13. On systems upgraded from a pre-2026-05-08 install, reaps any
    stale `semainputd` artifacts left from before the daemon was
    retired (the binary, its rc.d shim, its service directory,
    its `rc.conf` enable flag).

The supervision tree (s6-svscan + s6-supervise per daemon +
s6-log per daemon) replaces the previous direct rc.d management
and is the work tracked as AD-20 in `BACKLOG.md`. Operators
continue to use the standard `service <name> ...` commands;
the shims are transparent.

**Important:** `install.sh` does **not** add `inputfs_load` to
`/boot/loader.conf`. Do not add it manually. See Hazard 1 below.

**About the source tree post-install:** `install.sh` does not
relocate, copy, or remove the source tree. If you followed
Step 3's recommendation, the source remains at
`/usr/local/src/awase/` and can be left there for future rebuilds
(useful if you plan to track upstream or rebuild against a
debug kernel). If you want to reclaim disk space, `rm -rf` of
the source tree is safe after install completes; all deployed
artifacts live under `/usr/local/`, `/boot/`, `/var/service/`,
and `/etc/`, and none of them reference the source location.

**Verify:**

```
ls /usr/local/bin/semadrawd /usr/local/bin/semasound /usr/local/bin/chrono_dump
ls /usr/local/etc/rc.d/inputfs /usr/local/etc/rc.d/audiofs /usr/local/etc/rc.d/utf-supervisor
ls /usr/local/etc/rc.d/semasound /usr/local/etc/rc.d/semadraw
ls /var/service/utf/semasound/run /var/service/utf/semadrawd/run
ls /boot/modules/drawfs.ko /boot/modules/inputfs.ko
grep drawfs_load /boot/loader.conf
grep inputfs_load /boot/loader.conf  # should produce no output
```

Note the `semadraw` rc.d shim has no trailing `d`; the binary
under `/usr/local/bin/` is `semadrawd` (with the `d`); the s6
service directory under `/var/service/utf/` is named after the
binary (`semadrawd`). The mapping is not arbitrary — it preserves
the historical rc.d name operators may have in scripts while
keeping the s6 layout consistent with the binary names.
(`semasound` is the same name in all three roles.)

The last `grep` is a check, not a setup step: if it produces
output, something added `inputfs_load` and it must be removed
before the next reboot.

## Step 7 — Load drawfs

drawfs loads automatically at next boot via `/boot/loader.conf`
(install.sh writes this). To load it now without rebooting:

```
sudo kldload drawfs
```

**Verify:**

```
kldstat | grep drawfs
```

If `kldload drawfs` fails, run `dmesg | tail -50` and read the
error.

inputfs is *not* loaded here. inputfs is loaded by its rc.d service,
which is started in Step 8. inputfs cannot be loaded via
`/boot/loader.conf` (see Hazard 1) and must wait until `/var/run`
is mounted.

## Step 8 — Start Awase services

On a deployed PGSD system (this is what these install steps
produce), use the `service` interface. This is the only
path: the pre-AD-20 development launcher (`start.sh`) was
removed under F.6 (ADR 0029 Decision 4), since manual ordered
startup is the supervision architecture's job and a second,
unsupervised way to run the system is not wanted. For
development iteration, rebuild and `service <name> restart`.

```
sudo service inputfs start
sudo service utf-supervisor start
sudo service semadraw start
```

The order matters and is enforced at boot by `rcorder(8)`:

1. `inputfs` — loads the kernel module after `/var/run` is
   mounted, publishing `/var/run/sema/input/{state,events}`.
2. `utf-supervisor` — launches `s6-svscan /var/service/utf`
   as the supervision tree root. With it absent, the daemon
   shims have nothing to talk to.
3. `semadraw` - the compositor. Reads input directly from the
   inputfs ring; no intermediate daemon.

`semaaud` is RETIRED (F.6, ADR 0029, 2026-06-04). Its successor
`semasound` is the supervised audio broker, installed and enabled by
this step; `service semasound status` is the health check. On systems
upgraded from a pre-retirement install, install.sh reaps the stale
semaaud artifacts automatically (service directory with supervise
state, log directory, binary, rc.d script, and rc.conf key). The
audio clock at `/var/run/sema/clock` is written by the audiofs kernel
module (ADR 0018); the `audiofs` rc.d service PROVIDEs `utf_clock`.

The `service utf-supervisor start` call brings up
`s6-svscan`. `s6-svscan` then auto-spawns one `s6-supervise`
per service directory under `/var/service/utf/` and the daemons
come up under supervision a moment later. The subsequent
`service <name> start` calls send `s6-svc -uwu` to confirm the
service is up; when run from boot they are typically no-ops
because supervision has already started everything.

**Verify:**

```
kldstat | grep -E "drawfs|inputfs|audiofs"
service utf-supervisor status
service semasound status
service semadraw status
ls /var/run/sema/clock /var/run/sema/input/state /var/run/sema/input/events
```

`service utf-supervisor status` should report a pid and the
supervised services with real `s6-svstat` output (uptimes,
pids). The `service <name> status` calls are operator-side
shims that ultimately read the same s6-svstat. All three kernel
modules should be listed and the shared-memory regions should
exist.

If a supervised daemon dies repeatedly within 10 seconds of
start, the flap detector in `./finish` (see `s6/README.md`)
exits 125 after 5 such failures in a 45-second window; the
service is then marked down until operator intervention. Read
`/var/log/utf/<name>/current` for the daemon's own output and
`/var/log/utf/svscan.log` for s6-svscan's diagnostic lines.

### A note on rc.d naming

The rc.d shim is `semadraw`; the binary it supervises is
`semadrawd`; the `/var/service/utf/` directory is named
`semadrawd`. Old recipes that say `service semadrawd start`
will fail with "no such service"; the correct command is
`service semadraw start`. (`semasound` is the same name in
all three roles, no naming hop required.)

The `semainput` rc.d shim was retired 2026-05-08 along with the
`semainputd` daemon. Recipes that say `service semainput start`
or `service semainputd start` will fail with "no such service";
input now flows directly from the inputfs kernel module to
`semadrawd` via the shared event ring.

## Step 8.5 — Confirm the supervision tree shape

```
ps auxww | grep s6- | grep -v grep
```

A healthy tree shows the svscan pair plus, per supervised
service (`semasound`, `semadrawd`, `pgsd-sessiond`), a
supervise/log/logger/daemon quartet:

- 1 `daemon: /usr/local/bin/s6-svscan ...` (rc.d wrapper)
- 1 `s6-svscan /var/service/utf`
- 3 `s6-supervise <name>` (one per service)
- 3 `s6-supervise <name>/log` (one per log directory)
- 3 `s6-log ... /var/log/utf/<name>` (the loggers)
- 3 supervised daemons: `semasound`, `semadrawd`, `pgsd-sessiond`

Fewer processes than expected means one or more daemons did
not come up; check `service utf-supervisor status` to see
which.

## Step 9 — Run something

```
sudo /usr/local/bin/semadraw-term --scale 2
```

(Or `sudo semadraw/zig-out/bin/semadraw-term --scale 2` if you
skipped the install step.)

A terminal should appear on the framebuffer. Mouse and keyboard
should respond. If they don't, see Hazard 2.

If kernel log messages flash across the screen behind the
terminal — boot output, daemon startup lines, occasional dmesg
entries — that's the FreeBSD console (vt(4)) writing to the
same framebuffer drawfs is presenting on. To silence it for
the current session:

```
sudo conscontrol mute on
```

This is a workaround, not a fix. See Hazard 7 for the longer
explanation, and BACKLOG.md AD-10 for the structural item that
will eventually make this unnecessary.

If semadraw-term panics on the first character output — typically
before you have a chance to type — with an `index out of bounds:
index N, len M` message that does not visibly match the source
line in the trace, you are hitting **AD-14** (release-mode
optimization discrepancy in semadraw-term). The workaround is to
rebuild semadraw-term in Debug mode:

```
sudo sh scripts/build-debug-semadraw-term.sh
```

The Debug build runs the terminal correctly end-to-end. The
daemons stay ReleaseSafe (no known issues there). Re-running
`install.sh` later will restore the ReleaseSafe semadraw-term
and bring the panic back; until AD-14 closes, the Debug build
is the operational mode for the terminal client.

## Rebuilding

To rebuild from a clean tree (after pulling changes, editing
sources, or changing the Zig toolchain), just rerun the installer:

```
sh install.sh
```

`install.sh` clears the build artifacts itself before building:
it runs `clean.sh --force` as an early step, so a separate manual
clean is no longer required. To inspect or clean by hand:

```
sh clean.sh --dry-run   # list candidates without removing
sh clean.sh --force     # remove them
```

`clean.sh` removes every `.zig-cache/` and `zig-out/` directory
under the checkout plus the root-level `build-*.log` files. It
does not touch `.git/`, `.config`, source files, or anything
under `/usr/src`, `/boot`, or `/usr/obj`. The drawfs and inputfs
kernel modules under `/usr/src` are cleaned by their own
`build.sh` scripts, not by `clean.sh`.

`install.sh` then rebuilds every userland subproject (unprivileged),
rebuilds and redeploys the kernel modules, and reinstalls, exactly
as in Step 6. Because `install.sh` performs both the clean and the
userland build itself, a clean rebuild needs no separate `clean.sh`
or `build.sh` run.

A clean rebuild is the reliable way to pick up a Zig toolchain
change: stale `.zig-cache/` entries from a previous compiler
version are a common source of confusing build errors, and
clearing them removes that variable.

## Hazards

These are mistakes that have actually caused install-time crashes
or unrecoverable boots. Read them.

### Hazard 1 — Do NOT add `inputfs_load="YES"` to `/boot/loader.conf`

`inputfs.ko` cannot currently be loaded from `loader.conf`. Doing
so causes a kernel panic on next boot in `inputfs_state_worker`,
because the kthread starts before `/var/run` is mounted and
faults when it tries to create `/var/run/sema/input/`.

The recovery from this state requires booting from a FreeBSD
install USB and editing `/boot/loader.conf` from rescue mode —
not a quick fix.

`drawfs_load="YES"` is fine and is what `install.sh` adds. Only
inputfs has the early-boot crash.

inputfs is loaded by its dedicated rc.d service, installed by
`install.sh` to `/usr/local/etc/rc.d/inputfs`. The script declares
`REQUIRE: FILESYSTEMS`, so `rcorder(8)` runs `kldload inputfs`
after `/var/run` is mounted (no early-boot crash). The consumer
daemons (utf-supervisor and the three shims) express the inverse
direction with their own `REQUIRE:` lines, so they always come up
after inputfs.

The service is enabled in `/etc/rc.conf` as `inputfs_enable="YES"`
during install. To start it without rebooting:

```
sudo service inputfs start
```

Older installs of Awase and an earlier draft of this hazard
recommended adding `kldload inputfs` to `/etc/rc.local`. That
recipe is superseded by the rc.d service. If you have an
`/etc/rc.local` line from a previous install, remove it; the
rc.d service is the supported path.

The kernel-side fix that would let inputfs load from
`loader.conf` (defer the publication kthread's first mkdir
until rootfs is mounted via `mountroothold_register`, or
refuse to load when the `cold` flag is set) is its own
backlog item, not landed.

### Hazard 2 — Input may not work if HID drivers compete with inputfs

FreeBSD GENERIC includes `hkbd` and `ukbd` statically. These
attach to USB keyboards before inputfs sees them, leaving
inputfs with no devices to own. Symptoms: `kldstat` shows
inputfs loaded but `ls /var/run/sema/input/` shows the state
region has no devices, and keyboard input does not reach Awase
clients.

Resolutions, in increasing order of effort:

1. **Move the competing module files out of `/boot/kernel/`
   and rebuild `linker.hints`.** Quick, reversible. See
   `BACKLOG.md` AD-8 for context.

2. **Build and install the PGSD kernel.** This is the
   supported configuration for full Awase testing. See
   `pgsd-kernel/README.md` for the build steps, including the
   pkgbase-aware install path. Plan 30-60 minutes for the
   build.

3. **Use only mice and devices not claimed by `hkbd`/`ukbd`
   for initial testing.** Pointers attach via `hms` (also
   compiled in GENERIC); if you have an `hms`-using mouse the
   same competition occurs.

The PGSD kernel exists specifically to remove this competition.

### Hazard 3 — Filesystem corruption from interrupted installs

If a previous attempt at `make installkernel` or `pkg install`
was interrupted (kernel panic, power loss, ctrl-C in the wrong
moment), `/boot/kernel/` may be in a partial state where neither
the new kernel nor `kernel.old` boots. Symptom: every boot
selection panics identically very early.

The fix is a USB-rescue boot, mount the root, and either
restore `/boot/kernel/` from `/boot/kernel.old/` or reinstall
the pkgbase kernel (`pkg -c /mnt install -f FreeBSD-kernel-generic`).

Once the system boots cleanly, **do not retry the failed install
step until you understand what caused the original interruption.**
Repeated half-completes compound the corruption.

### Hazard 4 — Zig version mismatch

Zig point releases have substantial syntax and stdlib
differences. Awase targets 0.16; older toolchains (0.14, 0.15)
fail loudly with errors about reserved syntax, missing imports,
or wrong stdlib paths.

If `zig version` reports anything older than 0.16, install 0.16
from the official Zig downloads or wait for `pkg install zig` to
ship a 0.16 build for your FreeBSD version.

### Hazard 5 — `/var/run` not actually tmpfs

Step 1's verification is not optional. Awase's shared-memory
publication assumes tmpfs and may produce confusing failures
(stale region files from previous boots, write performance
degradation, file-mode mismatches) on a regular `/var/run`.
Always confirm `mount | grep /var/run` shows `tmpfs` before
proceeding.

### Hazard 6 — Building without `.config` on a fresh FreeBSD install

`semadraw`'s build defaults attempt to enable some optional
backends (Vulkan, X11, bsdinput) when no `.config` file is
present. On a fresh FreeBSD install without the supporting
ports, the link step then fails with errors like:

```
error: unable to find dynamic system library 'vulkan' ...
error: unable to find dynamic system library 'X11' ...
error: unable to find dynamic system library 'input' ...
error: unable to find dynamic system library 'udev' ...
```

The fix is to write `.config` before building, with all
optional backends explicitly disabled. Step 3.5 covers this.

A related symptom: missing `rsync` causes `drawfs/build.sh`
and `inputfs/build.sh` to fail at the install step with
`rsync: not found`. rsync is not in FreeBSD base; install it
explicitly per Step 2.

If you hit either failure mode mid-install, the fix is in the
build inputs (write `.config`, install `rsync`); no system
state needs to be unwound. Re-run `sh install.sh`.

### Hazard 7 — Kernel console writes to the same framebuffer

When semadraw-term (or any drawfs client) draws to the EFI
framebuffer, the FreeBSD console (vt(4)) is still writing to
that same physical memory. Boot messages, daemon startup output,
and any dmesg entries written after semadrawd takes over will
flash across the screen behind the Awase surface. Typing into
semadraw-term may also produce visible artifacts as vt(4)
redraws its scrollback.

This is not a Awase bug per se — drawfs maps the framebuffer for
its own use but does not negotiate exclusive ownership with
vt(4). A real Awase session needs that handshake (see BACKLOG.md
AD-10). Until that lands, the workaround is to mute the console:

```
sudo conscontrol mute on
```

Effect is immediate; no semadraw-term restart needed. To
re-enable kernel console output later:

```
sudo conscontrol mute off
```

The mute setting does not persist across reboots. If you want
it on at every boot, add to `/etc/rc.local`:

```
conscontrol mute on
```

**Boot-time mute has a real operational cost: the vt(4)
login prompt is also invisible.** With `conscontrol mute on`
in `/etc/rc.local`, the physical console comes up dark — no
login prompt, no boot messages, nothing. SSH access becomes
the only login path. Verified on 2026-05-04: a freshly
rebooted PGSD machine with the rc.local mute in place could
not be logged into from the keyboard until SSH'd in to
remove the rc.local entry.

For single-user dev machines where SSH is reliable, the
boot-time mute is acceptable. For multi-user systems or
unattended bare metal, it is a footgun: a network outage
plus a reboot leaves you with a machine you cannot reach.

Recommendation:

- **Single-user dev box, SSH always available**: rc.local
  mute is fine.
- **Multi-user or unattended hardware**: do *not* put
  `conscontrol mute on` in `/etc/rc.local`. Run it manually
  per session when starting a Awase surface, accept that
  early-boot kernel messages will be visible behind the
  surface during the brief startup window.
- **Either case**: the structural fix (BACKLOG.md AD-10;
  design in `drawfs/docs/adr/0001-framebuffer-ownership-at-boot.md`)
  is drawfs taking the framebuffer at boot before vt(4)
  attaches in the normal path, not a runtime VT_PROCESS
  negotiation. vt(4) stays compiled for `boot -s` recovery
  only. Until AD-10 is implemented, the mute workaround above
  is the mitigation.

Note that muting the console hides legitimate kernel diagnostic
output — panics, driver warnings, etc. — so even when the
mute is the right choice, do this only on a machine where you
have SSH access to read dmesg from another session.

A separate contributor to console flashing is documented in
BACKLOG.md AD-13: inputfs's interrupt handler logs every HID
report to `/dev/console`, so any keypress or mouse motion
produces a console line regardless of whether anything else
is logging. Once AD-13 lands (per-report logging behind a
sysctl, default off), the residual flashing is only
boot/dmesg traffic, which may make the rc.local mute
unnecessary altogether.

## Recovery checklist

If something goes wrong during install or first run, these are
the recovery steps in order:

1. **`service utf-supervisor stop`** — stop the s6 supervision
   tree first; this stops the three supervised daemons cleanly
   in a single step. With it stopped, `service <name> status`
   for the three shims will report "not supervised" rather
   than "down".
2. **`kldunload inputfs; kldunload drawfs`** — back out the
   kernel modules. Most issues localize here.
3. **`rm -rf /var/run/sema/`** — clear stale state regions.
   These are tmpfs-resident and disappear on reboot anyway,
   but clearing them lets you restart without rebooting.
4. **Reboot** — fresh state for everything user- and
   kernel-side.
5. **If reboot panics** — boot from FreeBSD USB rescue, mount
   the root, edit `/boot/loader.conf` to remove anything Awase
   added, and reboot. See Hazard 3.

## Uninstall

```
sh install.sh --uninstall
```

Run as your regular user; the uninstall re-execs its privileged
removals through `mdo` just as the install does. This removes the
installed binaries, rc.d service files, the
`drawfs_load` entry from `/boot/loader.conf`, and the daemon
enable flags from `/etc/rc.conf`. It does not remove the
source tree at `~/awase` or anything under `/var/run/sema/`
(transient; cleared on reboot).

## Next steps after a clean install

- Run the inputfs verification protocol at
  `inputfs/docs/D_VERIFICATION.md` to confirm the substrate is
  working.
- Read `BACKLOG.md` to see the open work surface.
- Read `docs/AWASE_ARCHITECTURAL_DISCIPLINE.md` for the framing
  that all the work descends from.

## Why this document exists

Awase's install steps were previously distributed across several
documents (`README.md`, `pgsd-kernel/README.md`, `install.sh`
comments, the inputfs proposal). A first-install operator had
to triangulate. This document is the single end-to-end walkthrough
plus the hazard list. The hazards section in particular captures
failure modes that have actually been hit during testing,
including the `inputfs_load` early-boot crash and the universal
panic from interrupted installs.

Updates to this document should be commit-paired with the change
that necessitated them: a new hazard discovered during testing
lands here in the same commit that fixes it (or, if no fix
exists yet, lands here with a clear "no fix yet" note).
