# Installing Awase on a fresh FreeBSD system

This document has two parts, because installing Awase and developing
Awase are different jobs with different steps.

- **Part 1, Installing** is for getting a working Awase system. It is
  a linear runsheet: prepare the machine, run the installer, install
  the PGSD kernel, reboot. You do not build individual components by
  hand; `install.sh` builds and installs the userland, the kernel
  modules, the services, and the supervision tree for you. If you
  want a working system, read Part 1 and stop.

- **Part 2, Developing** is for working on a component. It covers
  building a single subproject or kernel module without reinstalling
  everything, reloading a module against a running system, restarting
  one daemon, and the iterate loop. These steps are not part of an
  install and you do not need them to run Awase.

Parts 3 and 4 (Hazards, Recovery and uninstall) apply to both.

Every step in Part 1 has a verify block. Do not proceed past a step
whose check fails. The hazards section names the things that have
actually broken installs in the past.

`install.sh` runs as a regular user and elevates privileged steps
through `mdo` itself; it is not run under `sudo`. It does not build
the PGSD kernel: that is a separate, operator-invoked step (per ADR
0002), and on GENERIC the installer detects the missing kernel and
says so.


---

# Part 1 — Installing Awase

This is the whole install. Follow it top to bottom. You will not
build any component by hand: `install.sh` does that.

The shape is: prepare the machine (Steps 1 to 4), run the installer
(Step 5), install the PGSD kernel (Step 6), reboot and verify
(Steps 7 to 9).

## Prerequisites

- FreeBSD 15.1-RELEASE installed and bootable. ZFS or UFS root.
- Network access for `pkg install` and `git clone`.
- A `mac_do` rule that lets your user elevate to root (Step 0).
  `install.sh` runs as a regular user and elevates privileged
  steps through `mdo`; it is not run under `sudo`. If the rule
  is missing the installer detects it and prints the provisioning
  commands before doing any work.
- The `/usr/src` tree if you intend to build the PGSD kernel. You
  do not need to set this up by hand: the kernel build provisions
  it from the pinned fork with
  `sudo sh pgsd-kernel/pgsd-kernel-build.sh provision` (Step 6).
  Optional for first install; GENERIC works for staging, but the
  system is not runnable until the PGSD kernel is installed
  (Step 6).

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

The userland build uses a **vendored, pinned Zig** at
`sdk/zig/current` (bootstrapped automatically by `tools/zig` on
first build; needs network), so you do not `pkg install zig`. The
packages you do need are `gmake`/`rsync` for the kernel modules,
`git` for the clone, and `s6` for the daemon supervision tree
(introduced in AD-20):

```
sudo pkg install -y git gmake rsync s6
```

`rsync` is used by `drawfs/build.sh` and `inputfs/build.sh` to
copy module sources into `/usr/src/sys/`. It is not in FreeBSD
base. Without it, both kernel-module builds fail at the install
step with `rsync: not found`.

For the interactive backend selector in step 4 below, also
install `bsddialog`:

```
sudo pkg install -y bsddialog
```

`bsddialog` is optional — `configure.sh` falls back to a plain
text menu if it is absent — but the dialog menu is a clearer
interface and is recommended.

**Do not `pkg install FreeBSD-src`.** The PGSD kernel builds
against a *pinned FreeBSD fork*, not the pkgbase release source,
and the AD-57 pin check rejects an unpinned `/usr/src`. The kernel
build provisions the correct source itself in Step 6
(`pgsd-kernel-build.sh provision`); there is nothing to install
here for the kernel source.

**Verify:**

```
which s6-svscan
```

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

## Step 4 — Configure backend selection

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

## Step 5 — Run the installer

```
sh install.sh
```

Run as a regular user, not under `sudo`. `install.sh` does the whole
build and install: it cleans stale artifacts, builds the userland
(ReleaseSafe), builds and deploys the drawfs, inputfs, and audiofs
kernel modules, installs the binaries, generates the rc.d services
and the s6 supervision tree, and sets the enable flags. You do not
run `build.sh` or the per-module build scripts yourself; that is
developer work (Part 2).

This is the step that needs `mac_do` (Step 0): the build is
unprivileged, and only the deploy phase elevates.


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
   complete and print a notice pointing at Step 6.
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
   and `audiofs` (the latter PROVIDEs `awase_clock`, since loading
   audiofs starts the kernel clock writer; ADR 0018/0029), the
   `awase-supervisor` (s6-svscan launcher), and thin shims for
   `semasound`, `semadraw`, and `pgsd-sessiond` that translate
   `service <name> {start,stop,status,restart}` into the matching
   `s6-svc` calls.
9. Copies the s6 service-directory layout from `s6/awase/` to
   `/var/service/awase/` (one directory per supervised daemon).
10. Creates `/var/log/awase/` and per-daemon log subdirectories
    for `s6-log` to write into.
11. Sets `drawfs_load="YES"` in `/boot/loader.conf`.
12. Sets enable flags in `/etc/rc.conf`: `inputfs_enable`,
    `audiofs_enable`, `awase_supervisor_enable`, and the daemon
    shims `semasound_enable`, `semadraw_enable`,
    `pgsd_sessiond_enable`, plus `pgsd_bootchime_enable`.
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
ls /usr/local/etc/rc.d/inputfs /usr/local/etc/rc.d/audiofs /usr/local/etc/rc.d/awase-supervisor
ls /usr/local/etc/rc.d/semasound /usr/local/etc/rc.d/semadraw
ls /var/service/awase/semasound/run /var/service/awase/semadrawd/run
ls /boot/modules/drawfs.ko /boot/modules/inputfs.ko
grep drawfs_load /boot/loader.conf
grep inputfs_load /boot/loader.conf  # should produce no output
```

Note the `semadraw` rc.d shim has no trailing `d`; the binary
under `/usr/local/bin/` is `semadrawd` (with the `d`); the s6
service directory under `/var/service/awase/` is named after the
binary (`semadrawd`). The mapping is not arbitrary — it preserves
the historical rc.d name operators may have in scripts while
keeping the s6 layout consistent with the binary names.
(`semasound` is the same name in all three roles.)

The last `grep` is a check, not a setup step: if it produces
output, something added `inputfs_load` and it must be removed
before the next reboot.

## Step 6 — Build and install the PGSD kernel

The stock GENERIC kernel works for first install and basic Awase
testing, but several in-tree drivers compete with Awase for
ownership of hardware:

- `hkbd`, `ukbd`, `hms`, `hmt`, `hgame`, `hcons`, `hsctrl`,
  `hpen`, `hconf`, `hidmap`: HID class drivers that claim
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

**Ordering.** Run the kernel `install` phase only after Step 5 has
deployed the userland: the kernel's AD-8 closure check refuses to
install until `/boot/modules/drawfs.ko` is on disk (a PGSD kernel
booting with no drawfs.ko comes up dark). The `check` phase and the
30-60 minute `build` phase can run at any time before that.

**Quickstart.** The kernel steps, in the working order around
Step 5:

```
sudo sh pgsd-kernel/pgsd-kernel-build.sh provision   # clone the pinned fork into /usr/src
sh pgsd-kernel/pgsd-kernel-build.sh check
mdo sh pgsd-kernel/pgsd-kernel-build.sh build --clean
sh install.sh                                # Step 5 (deploys drawfs.ko)
mdo sh pgsd-kernel/pgsd-kernel-build.sh install
mdo shutdown -r now
```

The `provision` phase populates `/usr/src` with the pinned FreeBSD
fork the kernel builds against (reading `pgsd-kernel/FREEBSD-PIN`).
It is a deliberate, destructive step (a multi-GiB clone that replaces
`/usr/src`), owned by the kernel build because `/usr/src` exists only
for the kernel: the userland install never uses it. Run it once on a
fresh machine; it is idempotent when `/usr/src` is already the pinned
fork, and it confirms before replacing a non-empty tree (pass `--yes`
to skip the prompt). If you provisioned `/usr/src` some other way (a
manual clone at the pinned commit), skip it; `check` verifies the pin
regardless.

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

## Step 7 — Reboot onto the PGSD kernel

```
mdo shutdown -r now
```

The reboot is what puts the PGSD kernel and the modules in place:
drawfs loads from `/boot/loader.conf` (which `install.sh` wrote),
inputfs and audiofs load from their rc.d services, and the
supervision tree starts. Loading modules by hand is developer work
(Part 2); a normal install just reboots.

**Verify:**

```
uname -a
```

The banner must name the PGSD kernel, for example
`FreeBSD 15.1-RELEASE ... n283562-96841ea08dcf PGSD amd64`. If it
still says GENERIC, the kernel install did not take: go back to
Step 6.

## Step 8 — Confirm the services are running

On a deployed PGSD system (this is what these install steps
produce), use the `service` interface. This is the only
path: the pre-AD-20 development launcher (`start.sh`) was
removed under F.6 (ADR 0029 Decision 4), since manual ordered
startup is the supervision architecture's job and a second,
unsupervised way to run the system is not wanted. For
development iteration, rebuild and `service <name> restart`.

```
sudo service inputfs start
sudo service awase-supervisor start
sudo service semadraw start
```

The order matters and is enforced at boot by `rcorder(8)`:

1. `inputfs` — loads the kernel module after `/var/run` is
   mounted, publishing `/var/run/sema/input/{state,events}`.
2. `awase-supervisor` — launches `s6-svscan /var/service/awase`
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
module (ADR 0018); the `audiofs` rc.d service PROVIDEs `awase_clock`.

The `service awase-supervisor start` call brings up
`s6-svscan`. `s6-svscan` then auto-spawns one `s6-supervise`
per service directory under `/var/service/awase/` and the daemons
come up under supervision a moment later. The subsequent
`service <name> start` calls send `s6-svc -uwu` to confirm the
service is up; when run from boot they are typically no-ops
because supervision has already started everything.

**Verify:**

```
kldstat | grep -E "drawfs|inputfs|audiofs"
service awase-supervisor status
service semasound status
service semadraw status
ls /var/run/sema/clock /var/run/sema/input/state /var/run/sema/input/events
```

`service awase-supervisor status` should report a pid and the
supervised services with real `s6-svstat` output (uptimes,
pids). The `service <name> status` calls are operator-side
shims that ultimately read the same s6-svstat. All three kernel
modules should be listed and the shared-memory regions should
exist.

If a supervised daemon dies repeatedly within 10 seconds of
start, the flap detector in `./finish` (see `s6/README.md`)
exits 125 after 5 such failures in a 45-second window; the
service is then marked down until operator intervention. Read
`/var/log/awase/<name>/current` for the daemon's own output and
`/var/log/awase/svscan.log` for s6-svscan's diagnostic lines.

### A note on rc.d naming

The rc.d shim is `semadraw`; the binary it supervises is
`semadrawd`; the `/var/service/awase/` directory is named
`semadrawd`. Old recipes that say `service semadrawd start`
will fail with "no such service"; the correct command is
`service semadraw start`. (`semasound` is the same name in
all three roles, no naming hop required.)

The `semainput` rc.d shim was retired 2026-05-08 along with the
`semainputd` daemon. Recipes that say `service semainput start`
or `service semainputd start` will fail with "no such service";
input now flows directly from the inputfs kernel module to
`semadrawd` via the shared event ring.

## Step 9 — Confirm the supervision tree shape

```
ps auxww | grep s6- | grep -v grep
```

A healthy tree shows the svscan pair plus, per supervised
service (`semasound`, `semadrawd`, `pgsd-sessiond`), a
supervise/log/logger/daemon quartet:

- 1 `daemon: /usr/local/bin/s6-svscan ...` (rc.d wrapper)
- 1 `s6-svscan /var/service/awase`
- 3 `s6-supervise <name>` (one per service)
- 3 `s6-supervise <name>/log` (one per log directory)
- 3 `s6-log ... /var/log/awase/<name>` (the loggers)
- 3 supervised daemons: `semasound`, `semadrawd`, `pgsd-sessiond`

Fewer processes than expected means one or more daemons did
not come up; check `service awase-supervisor status` to see
which.

## Step 10 — Run something

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


---

# Part 2 — Developing Awase

Nothing in this part is needed to install or run Awase. Part 1 is
the install; `install.sh` builds and deploys every component for
you. This part is for working on a component: building one
subproject or one kernel module without reinstalling everything,
loading it against a running system, and iterating.

It assumes you already have a working install from Part 1 (a PGSD
kernel, `/usr/src` provisioned, dependencies present, `.config`
written).

## Building the userland without installing

The top-level `build.sh` builds every userland Zig subproject:
`semasound`, `chronofs`, and `semadraw`. The `semainput` subproject
no longer produces an executable (the daemon was retired
2026-05-08); only `libsemainput` remains, consumed by `semadrawd`
at build time.

```
sh build.sh
```

This is what `install.sh` runs internally, so use it to check that
your change compiles without doing a full install. Build outputs
land in each subproject's `zig-out/bin/`. The build uses the
vendored Zig at `sdk/zig/current` (see Hazard 4), not a system Zig.

To build a single subproject, run its own `build.sh`, for example:

```
sh semadraw/build.sh
```

## Building a kernel module without installing the rest

drawfs, inputfs, and audiofs are FreeBSD kernel modules built
against `/usr/src` via per-module helper scripts. The full sequence
runs as part of `install.sh`, so this is only for development
iteration on one module:

```
sudo sh drawfs/build.sh install
sudo sh drawfs/build.sh build
sudo sh drawfs/build.sh deploy
sudo sh inputfs/build.sh install
sudo sh inputfs/build.sh build
sudo sh inputfs/build.sh deploy
```

Each helper copies the
module sources into `/usr/src/sys/`, runs `make`, and copies the
resulting `.ko` to `/boot/modules/`. The subcommands are:

- `install` copies sources into `/usr/src/sys/`
- `build` runs `make` against them
- `deploy` copies the built `.ko` to `/boot/modules/`
- `load` kldloads the module

**Verify:**

```
ls /boot/modules/drawfs.ko
ls /boot/modules/inputfs.ko
```

## Loading a module against a running system

drawfs loads automatically at boot from `/boot/loader.conf` (which
`install.sh` writes). To load a freshly built one now, without
rebooting:

```
sudo kldload drawfs
```

**Verify:**

```
kldstat | grep drawfs
```

Note Hazard 1: do NOT add `inputfs_load="YES"` to
`/boot/loader.conf`. inputfs must load from its rc.d service, not
the loader.

## The iterate loop

To rebuild after editing sources, rerun the installer:

```
sh install.sh
```

`install.sh` clears the build artifacts itself before building: it
runs `clean.sh --force` as an early step, so a separate manual
clean is not needed. This is the safest loop, because it rebuilds
and redeploys everything consistently.

To clean by hand (to inspect what would be removed, or to reset a
tree without installing):

```
sh clean.sh --dry-run
sh clean.sh --force
```

`clean.sh` removes build outputs (`.zig-cache/`, `zig-out/`) inside
the checkout. It deliberately does not touch `sdk/zig/`, so the
vendored toolchain is not re-bootstrapped on every clean.

For a faster loop on one component, build just that component (see
above), deploy it, and restart only its service rather than
reinstalling. The supervised daemons are `semadrawd`, `semasound`,
and `pgsd-sessiond` under the s6 tree at `/var/service/awase/`.


---

# Part 3 — Hazards

These apply whether you are installing or developing. Each one has
actually broken an install.


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
daemons (awase-supervisor and the three shims) express the inverse
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

### Hazard 4 — Vendored Zig toolchain bootstrap

Awase builds only through the vendored, pinned Zig at
`sdk/zig/current`, invoked via `tools/zig`, which bootstraps it on
first use. You do not use a system `pkg install zig`, so a system
Zig of the wrong version is irrelevant; `build.sh` and `install.sh`
ignore it.

The real hazard is the bootstrap: `tools/zig` fetches and unpacks
the pinned toolchain into `sdk/zig/current` on first build, which
needs network. If that first build ran under `sudo` in an older
workflow, `sdk/` can be left root-owned and a later unprivileged
build fails; `install.sh` repairs this (it re-chowns a root-owned
`sdk/`), but if you hit it standalone, `chown -R` your user over
`sdk/` and rebuild. If the bootstrap cannot reach the network, the
build stops with guidance rather than a misleading "ok vendored
zig".

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
optional backends explicitly disabled. Step 4 covers this.

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


---

# Part 4 — Recovery, uninstall, and reference

## Recovery checklist

If something goes wrong during install or first run, these are
the recovery steps in order:

1. **`service awase-supervisor stop`** — stop the s6 supervision
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
