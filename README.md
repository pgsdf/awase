# Awase

Awase is a unified temporal fabric for FreeBSD: the core of the
PGSDF multimedia system. The name (from Japanese awaseru, to bring
together, to align) was ratified 2026-06-12; the project was
formerly named UTF, and historical documents (BACKLOG-history,
session records, ratified ADR texts) retain that name as record.
Awase brings graphics, sound, and input into one codebase, with the shared protocols, event formats, session identity, and timing that make them work as one system.

Its central part is chronofs, which keeps graphics, sound, and input on the same clock. That clock comes straight from the audio hardware through audiofs, so the system stays in step by design, not by later correction.

Awase is built for PGSD on FreeBSD; it no longer targets GhostBSD. Earlier work used GhostBSD as a development host, but the project now supports FreeBSD only and ships its own kernel configuration.

---

## Current state (2026-06-10)

What is built and verified:

- **chronofs** is complete (C-1 through C-5 closed): the clock
  module, event-stream buffers, resolver, audio-driven frame
  scheduler, and `chrono_dump`. The temporal layer is done.
- **inputfs** is the production input substrate. AD-2 closed
  2026-05-17: the legacy `semainputd` daemon is retired, Phase 2.5
  is verified on bare-metal hardware, and `semadrawd` reads
  `inputfs` directly. The input cutover is done, not pending.
- **drawfs**, **semadraw**, and the **shared/** infrastructure
  (event schema, session identity, clock region, protocol
  constants) are in place. **semaaud** is retired (F.6, ADR 0029,
  2026-06-04); its successor `semasound` is the installed, enabled,
  boot-supervised audio broker (F.5 complete, ADRs 0021/0024-0028),
  and install.sh reaps leftover semaaud artifacts from upgraded
  systems. See AD-3 in `BACKLOG.md`.
- The **inputfs gesture library** (`libsemainput`) now carries the
  reusable input semantics; that move is recorded and in progress.
- The **audiofs** kernel substrate is up. Commits 1 through 6g
  landed 2026-05-21: a class-matched PCI HDA driver, full
  HDA-spec output bring-up, and an audible test signal through the
  Apple iMac internal speaker at module load. The same series
  removed the `snd(4)` framework from the PGSD kernel in full
  (Option A). The decision owner un-gated AD-3 on 2026-05-20;
  spec-compliant bring-up, verified by hardware readback, then
  discharged the gate empirically. The full Stage F data path
  followed: F.1 through F.4 and F.3.e were bench-verified by
  2026-06-01, ADRs 0022/0023 resolved the DMA-boundary hum, and
  F.3.f (HDMI) is deferred behind an Awase-provided display
  capability.

What is decided and partly done:

- **audiofs userspace** (the `semasound` daemon) is done. F.5 is
  complete (mixing, format adaptation and election, named targets,
  Phase 12 policy parity with reference-counted ducking, state
  publication, s6 supervision; ADRs 0021/0024-0028), and semaaud is
  retired under F.6 (ADR 0029).
- **audiofs is now the clock writer** as of F.4 (ADR 0018, accepted
  2026-06-01, bench-verified on pgsd-bare-metal): the kernel
  publishes `/var/run/sema/clock` through a wired shared mapping of
  the file, replacing semaaud's userland writer. The wire format is
  unchanged (ADR 0003). `shared/CLOCK.md` carries the
  writer-transition note, and keeps its `ClockWriter` only as a test
  fixture. semaaud's retirement (F.6) completed 2026-06-04 (ADR
  0029).

What is deliberately not yet started:

- The desktop environment and application ecosystem (NDE, the
  semantic desktop layer; ratified semantic-native 2026-06-12, LT-3
  retired). These waited on a stable substrate, and the
  substrate is now stable: the input cutover closed 2026-05-17
  (AD-2) and the audio cutover closed 2026-06-05 (F.6, ADR 0029).
  Nothing now blocks the upper layers; they are unstarted
  by choice of priority, not by any dependency.

The substrate work that this list used to enumerate is done:
semasound runs against audiofs (F.5), the input cutover is executed
(AD-2), and the legacy daemons are retired (semainputd 2026-05-08,
semaaud 2026-06-05). AD-3 sits at its maintained end-state under ADR
0030: stewardship and scope are ratified, change classes K/B/P/T/R
and the takeover protocol govern all later audio work, and the
production suite mode is proven against the supervised broker. F.3.f
(HDMI) stays a live deferred entry. `BACKLOG.md` tracks the other
open AD items; `BACKLOG-history.md` holds the completed chronicle.

Session management has begun to build on that stable base. The
`pgsd-sessiond` graphical login already runs supervised at boot
(SM-1.9). Since 2026-06-05 the secure-session design has landed: the
screen-lock daemon (SM-2, ADR 0010) and idle-and-power management
(SM-3, ADR 0009) were accepted 2026-06-09, both resting on a
compositor that can enforce a lock. That compositor primitive is
D-10 (semadraw session-lock mode, ADR 0012, accepted 2026-06-09);
its first protocol constants have landed, but the lock state machine
and enforcement are not yet built, so SM-2 and SM-3 implementation
waits on it. The idle side already has its first piece in service:
D-11 (ADR 0013) publishes the last-input time through an
`idle_query`/`idle_reply` exchange, implemented and bench-verified on
pgsd-bare-metal and closed 2026-06-09. See `## SM: Session
Management` and the semadraw D-10 and D-11 entries in `BACKLOG.md`.

---

## Substrate and distribution

This monorepo holds two architecturally distinct projects that share
one workspace for convenience.

**Awase is the substrate:** the kernel modules and userland services
that provide a unified temporal fabric for input, audio, graphics,
and time. Awase has stable contracts (the kernel/userland boundary,
the shared-memory regions under `/var/run/sema/`, the IPC protocols)
that another distribution could in principle adopt to build a
different desktop on top. Awase holds no opinion about users, sessions,
login, or desktop environment; it deals in uids from `getpeereid(3)`
and in surfaces from clients.

Awase userland services use the `sema-` prefix: `semadrawd` and
`semasound` (their predecessors `semainputd` and `semaaud` are
retired). Kernel modules use the `*fs` convention: `drawfs`,
`inputfs`, `chronofs`, and `audiofs` (architecture decided in ADRs
0002-0008; F.0 closed, closure bookkeeping reconciled by ADR 0009
accepted 2026-05-19; kernel-side implementation through commits 1
to 6g landed 2026-05-21, with audible output verified on the
pgsd-bare-metal iMac internal speaker; the Stage F chain F.0 through
F.6 is complete under ADRs 0001-0029, with the maintenance model
owed; see AD-3 in BACKLOG).

**PGSD is the distribution:** a FreeBSD distribution built on Awase,
aimed at scientific and METOC visualization. PGSD makes the choices
Awase deliberately leaves open: which desktop environment to ship
(NDE), how to manage sessions and login (`pgsd-sessiond`), what
application layer to provide (LT), what default
applications, and what kernel configuration. Another distribution
built on Awase could choose differently in any of these.

PGSD components use the `pgsd-` prefix, so the layer split shows at
the process level: `pgsd-sessiond` for session management, with
future `pgsd-*d` daemons as the distribution grows. `ps` output on a
PGSD system tells the operator which layer each process belongs to.

PGSD currently has three component tracks, all in BACKLOG:

  - **NDE** (Native Desktop Environment): surface manager, system
    bar, launcher, and X11 compatibility bridge. PGSD's default
    desktop. See `## NDE` in `BACKLOG.md`.
  - **LT** (Layer Tree): the retained layer tree and chronofs-driven
    animation engine (LT-3, the GNUstep backend, retired 2026-06-12;
    NDE is semantic-native). See `## Long-term: Retained Layer
    Model on Awase` in `BACKLOG.md`.
  - **SM** (Session Management): graphical login, session lifecycle,
    screen lock, and idle and power management. Opened 2026-05-10
    from work first scoped under NDE. See `## SM: Session
    Management` in `BACKLOG.md`. The first daemon (`pgsd-sessiond`)
    runs supervised and starts at boot (SM-1.9: the system boots to
    its graphical login); its design is at
    `pgsd-sessiond/docs/adr/0001-design.md`.

BACKLOG reflects this split. Awase substrate work is filed under `##
Architectural Discipline` with `AD-*` identifiers; distribution work
is filed under its track with a track prefix (`NDE-*`, `LT-*`,
`SM-*`).

The architecture diagram below shows the Awase substrate only.
Distribution components consume the substrate through its stable
contracts and are not drawn here; their architecture lives in the
per-track design documents.

---

## Architecture

```
     Applications                     audio clients
          |                                |
     libsemadraw                       semasound
     (SDCS streams)                 (mixing broker:
          |                      targets, policy, state)
     semadrawd <---- inputfs               |
     (compositor)    (HID kernel        audiofs
          |           substrate)     (kernel audio:
       drawfs             |           PCI HDA, clock
     (/dev/draw)      hardware           writer)
          |           (USB HID)            |
       hardware                      hardware (HDA)
 (EFI framebuffer /
  Vulkan / X11)

   chronofs aligns all three domains against the
   audiofs-written clock at /var/run/sema/clock.
```

AD-2a Phase 3 (2026-05-08) deleted the `semainputd` daemon and moved
its gesture logic into `libsemainput`, used by the compositor and by
clients. The Stage E cutover followed and AD-2 closed 2026-05-17:
`semadrawd` reads straight from the inputfs ring at
`/var/run/sema/input/events`, and no Awase code path uses evdev. On the
audio side, `semasound` is the supervised broker over the `audiofs`
kernel substrate (F.5, ADRs 0021/0024-0028); `semaaud` retired under
F.6 (ADR 0029, 2026-06-05).

| Component | Role |
| --- | --- |
| drawfs | Kernel graphics transport. `/dev/draw` character device, surface lifecycle, mmap-backed pixel buffers, EFI framebuffer blit. |
| semadraw | Semantic rendering. SDCS command streams, the `semadrawd` compositor, software and hardware backends. |
| semasound | Audio mixing broker (AD-3, F.5). Unix-socket clients, named mixing targets, format adaptation and hardware-rate election, Phase 12 policy with reference-counted ducking, state publication under `/var/run/sema/audio/`, s6-supervised and started at boot. Sole writer to `/dev/audiofs0`. Predecessor `semaaud` retired under F.6 (ADR 0029). |
| semainput | Retired daemon directory. The `semainputd` evdev daemon retired 2026-05-08 (AD-2a Phase 3); only the `libsemainput` gesture library remains. The Stage E cutover in semadrawd was a separate, now-completed step. |
| inputfs | Kernel input substrate. Attaches at hidbus, parses HID reports, and publishes input state and events to userspace through shared memory under `/var/run/sema/input/`. The production input source; AD-2 closed 2026-05-17. |
| shared/ | Protocol constants, event schema, session identity, clock interface. |
| chronofs | Temporal coordination layer. Audio-driven frame scheduler, ring buffers, clock publication. |
| audiofs | Kernel audio substrate. Replaces the OSS dependency, owns the audio hardware end to end (PCI HDA, class-matched, vendor-agnostic), and writes the audio clock chronofs reads. Stage F complete, F.0 through F.6 (ADRs 0001-0029): kernel data path, clock writer (F.4, ADR 0018), format negotiation; semasound delivered above it and semaaud retired. Maintenance model owed; see AD-3 in BACKLOG. |

---

## Repository Layout

```
Awase/
├── drawfs/          kernel module and protocol (FreeBSD 15)
├── inputfs/         kernel input substrate (FreeBSD 15)
├── audiofs/         kernel audio substrate (FreeBSD 15; class-matched PCI HDA; AD-3 commits 1-6g landed 2026-05-21)
├── semadraw/        semantic rendering daemon and client library
├── semasound/       audio mixing broker (AD-3, F.5)
├── semainput/       libsemainput gesture library (daemon retired 2026-05-08)
├── shared/          cross-cutting constants, schema, and interfaces
├── chronofs/        temporal coordination layer
├── pgsd-sessiond/   PGSD distribution layer: graphical login daemon (SM-1.9, supervised, boots to login)
├── pgsd-kernel/     PGSD distribution layer: kernel config omitting inputfs-superseded drivers (AD-8)
├── s6/              Awase supervision tree, installed to /var/service/utf/ (AD-20)
├── scripts/         devfs rulesets, periodic jobs, bench helpers (installed rc.d shims are generated by install.sh)
├── BACKLOG.md       consolidated project backlog (source of truth)
├── BACKLOG-history.md  archive of closed entries and historical records
└── docs/
    ├── Thoughts.md                  chronofs architecture
    ├── PROTOCOL_MISMATCH_FINDINGS.md  integration audit (resolved)
    └── sessions/                    per-session working memos
```

---

## Subsystems

### drawfs

A FreeBSD kernel module that exposes `/dev/draw`. Clients open the
device, negotiate over a binary framed protocol, create surfaces
backed by swap memory, map them with `mmap(2)`, render into the pixel
buffer, and present. The kernel is not a compositor; policy lives in
userspace.

Phase 1 is complete: surface lifecycle, mmap, the framed binary
protocol, and input-event injection. Phase 2 adds EFI framebuffer
support: the module maps the UEFI GOP framebuffer at load time and
exposes the `DRAWFSGIOC_BLIT_TO_EFIFB` and `DRAWFSGIOC_GET_EFIFB_INFO`
ioctls, so semadrawd can render straight to the physical display on
bare-metal FreeBSD with no GPU driver. Verified on Intel Bay Trail
(1024x768) and the Apple iMac (3840x2160).

DRM/KMS support is a skeleton, gated behind `DRAWFS_DRM_ENABLED` at
build time and strictly optional. The EFI framebuffer path is the
default bare-metal display path and needs no DRM.

See `drawfs/docs/` for the protocol specification, architecture, and
build instructions.

### semadraw

A userspace semantic graphics system. Applications link against
`libsemadraw` and produce SDCS (Semantic Draw Command Streams):
binary sequences of drawing operations that express intent rather
than GPU commands. `semadrawd` owns surface composition and
presentation. Backends include software (the reference), Vulkan,
DRM/KMS, X11, Wayland, and drawfs.

`semadraw-term` is a native terminal emulator built on libsemadraw.
It supports multi-session operation (up to 8 sessions), a session
status bar, VT100/xterm-256color emulation, display-size
auto-detection through `DRAWFSGIOC_GET_EFIFB_INFO`, and font scaling
for HiDPI displays. It runs on bare-metal FreeBSD through the drawfs
EFI framebuffer backend, and on FreeBSD with Xorg through the X11
backend.

See `semadraw/docs/` for the SDCS specification, architecture, and
API overview.

### semasound

The audio mixing broker (AD-3, F.5). Clients connect over the Unix
socket at `/var/run/sema/audio.sock`, identify with a Hello v3 header
(format, target, label, class), and stream PCM. The broker mixes per
named target (`default` on `/dev/audiofs0`, `null` as a paced discard
sink), adapts formats with a windowed-sinc resampler and a
rate-correcting predictor, elects the hardware rate per session
opener for bit-exact passthrough, enforces the Phase 12 policy
grammar (allow, deny, override-as-ducking, group exclusivity,
admission fallback) with live reload, and publishes per-target state,
clients, and events under `/var/run/sema/audio/`. It runs
s6-supervised and starts at boot; `semasound-tone` and
`semasound-dump` are its test client and read-only inspector.

Its predecessor `semaaud` (the OSS routing daemon) retired under F.6
(ADR 0029, 2026-06-05) after the parity audit found no live
dependents; ADRs 0026/0027 record the policy contract semasound
preserves, and `BACKLOG-history.md` holds the historical chronicle.

See `semasound/docs/SUPERVISION.md` for operation, and ADRs 0020-0029
in `audiofs/docs/adr/` for the decision record.

### semainput

Historically the legacy userspace input daemon: it read evdev
devices, classified them by capability fingerprint, aggregated
physical devices into stable logical identities, applied pointer
smoothing, and emitted structured JSON-lines events for semantic
input (mouse, keyboard, touch) and gestures (two-finger scroll,
pinch, three-finger swipe, drag, tap).

That daemon (`semainputd`) retired on 2026-05-08 under AD-2a Phase 3:
the daemon binary, the `semainput/src/` tree, the rc.d shim, and the
s6 service directory were deleted. Its gesture-recognition logic was
not lost; it had moved into `libsemainput` (AD-2a Phase 2.3), now the
only userland surface left under `semainput/` and used directly by
semadrawd. See `semainput/README.md` and
`semainput/libsemainput/README.md` for current state.

The daemon retirement and the evdev cutover were separate steps, and
both are done: Stage E (the AD-2a cutover) executed and AD-2 closed
2026-05-17. semadrawd reads the inputfs ring directly; the evdev
reader and the `drawfs_inject` adapter are gone; no Awase runtime path
touches evdev.

See `semainput/docs/` for the architecture and system-interface
documentation of the historical daemon. It is kept for the design
record and describes nothing currently running.

### shared/

Protocol constants for all three binary protocols (drawfs, semadraw
IPC, SDCS) in a single JSON source of truth. A code generator emits C
headers and Zig constant declarations. A unified event schema,
session identity module, and clock publication interface serve all
four daemons.

### chronofs

A temporal coordination layer that makes time a first-class
addressable medium across all four subsystems. The audio hardware
clock drives a shared monotonic counter. Every event carries an
audio-sample timestamp. The frame scheduler queries scene state at a
target audio position rather than at wall time, which produces
drift-free AV synchronization by construction.

The implementation is complete across all dependency waves: clock
publication (`/var/run/sema/clock`), ring buffers, the resolver, the
audio-driven frame scheduler, and the `chrono_dump` diagnostic tool.

See `docs/Thoughts.md` for the full design and `chronofs/BACKLOG.md`
for the implementation history.

### inputfs

A FreeBSD kernel module that owns the HID input path. inputfs
attaches at `hidbus`, parses HID report descriptors, registers
interrupt callbacks, and publishes input state and events to
userspace through shared-memory regions under `/var/run/sema/input/`.
The state region carries the materialised view (current pointer
position, device inventory, per-device keyboard and touch state)
updated under a seqlock; the event ring carries an ordered delta
stream read through the `EventRingReader` in `shared/src/input.zig`.

Stage A delivered the design (proposal, foundations, ADRs 0001
through 0011, four byte-level companion specs). Stage B delivered HID
attachment, descriptor parsing, interrupt-handler registration, and
per-device role classification. Stage C delivered userspace
publication of the state region and event ring, the `inputdump`
diagnostic CLI, and a verification protocol at
`inputfs/docs/C_VERIFICATION.md` that runs 26 automated checks plus a
manual mouse-and-button checklist. Stage D (focus routing and
coordinate transform) landed across eight sub-stages (D.0a through
D.6); AD-9's fuzzing work hardened the parser before the cutover
proceeded.

inputfs replaced `semainput` (the userspace evdev daemon) on the PGSD
target: the Stage E cutover executed and AD-2 closed 2026-05-17. Awase
runs on inputfs alone, with no evdev fallback in any code path, by
deliberate commitment to the discipline at
`docs/UTF_ARCHITECTURAL_DISCIPLINE.md`.

inputfs also feeds FreeBSD's `vt(4)` console keyboard input through a
bridge driver (the `inputfs_kbd` kbd-layer driver inside the inputfs
module). Each HID keyboard inputfs attaches becomes a slave of
`kbdmux`, which feeds vt(4)'s console keystroke pipeline. So console
login at ttyv0 works on a PGSD kernel that loads no legacy hkbd (per
AD-8's WITHOUT_MODULES discipline). The bridge is gated by
`hw.inputfs.kbdmux_bridge` (default 1) and documented in ADR 0019
(`inputfs/docs/adr/0019-kbdmux-bridge.md`).

See `inputfs/docs/` for the proposal, foundations, ADRs, byte-level
specs, and verification protocols.

### audiofs

A FreeBSD kernel module that owns audio hardware end to end,
replacing the OSS dependency `semaaud` wrote to. audiofs is the
audio-side counterpart to inputfs: a kernel substrate that owns the
device and publishes to userland, rather than a userspace daemon
talking to a legacy device node. It is also the kernel-side writer of
the audio hardware clock that chronofs reads, which closes the
temporal fabric on the side it originates from.

audiofs is a direct PCI driver that class-matches on PCI HDA
controllers (class `MULTIMEDIA`, subclass `MULTIMEDIA_HDA` per the
PCI spec). The match is vendor-agnostic: any HDA controller attaches
through the same probe, whatever the silicon vendor. On
pgsd-bare-metal this covers both the Intel Sunrise Point analog HDA
controller and the ATI Oland HDMI audio controller. The `snd(4)`
framework is removed from the PGSD kernel in full; see the kernel
config comment at `pgsd-kernel/PGSD` (sound section) for the
consolidated rationale.

The work is tracked as AD-3 in `BACKLOG.md` (Stage F of
`audiofs/docs/audiofs-proposal.md`). The architecture phase, F.0, is
closed: ADRs 0001 through 0008 record the decisions (OSS coexistence,
clock writer, mixer location, userland architecture, the `snd(4)`
full replacement, the physics/semantics boundary, and Stage F scope),
and ADR 0009 reconciles the F.0 closure bookkeeping by recording how
each of the proposal's six open questions was dispositioned. The
ADR-before-code discipline held: every architectural commitment
landed in an ADR before any audiofs kernel code was written.

Stage F is complete (F.0 through F.6, ADRs 0001-0029). The commit-6.x
series (2026-05-21) brought up the full HDA-spec output path on
`pgsd-bare-metal`: PCI attach, controller reset, CORB/RIRB DMA, codec
enumeration, widget topology walk, output-path discovery, power-state
management, pin output enable, amp unmute, format binding, BDL setup,
audible buffer fill, stream-tag binding, RUN, and position tracking.
Commit 6g added the platform-policy layer that asserts the Apple
iMac's internal speaker amplifier through standard HDA GPIO verbs at
attach; the iMac's internal speaker then produces audible output
automatically at module load.

The chain above the kernel followed: the data path (F.1-F.3.e), the
kernel clock writer (F.4, ADR 0018), the `semasound` broker (F.5,
ADRs 0021/0024-0028, supervised and boot-started), and the retirement
of semaaud and with it the last OSS dependency (F.6, ADR 0029,
2026-06-05). Still owed: the maintenance model (ADR 0030, proposed
2026-06-05), covering stewardship, per-chipset evidence
responsibility, change classes, and the operational regime.

See `audiofs/docs/adr/` for the decision record,
`audiofs/docs/audiofs-proposal.md` for the Stage F design, and AD-3
in `BACKLOG.md` for the current implementation status.

---

## System Requirements

Awase targets PGSD-on-FreeBSD 15.0-RELEASE. Beyond a working FreeBSD
installation, two system-level settings are required for the daemons
and kernel modules to work correctly.

For an end-to-end walkthrough of installing Awase on a fresh FreeBSD
system, including hazards that have actually broken installs (in
particular: do not add `inputfs_load="YES"` to `/boot/loader.conf`),
see [`INSTALL.md`](INSTALL.md).

### `/var/run` must be tmpfs

Several Awase components publish state to userland through
shared-memory regions under `/var/run/sema/`: the audio clock at
`/var/run/sema/clock` (written by the audiofs kernel module), the
session token at `/var/run/sema/session`, and the inputfs state
region at `/var/run/sema/input/state` (Stage C onward). These files
are recreated on every daemon or module load and mean nothing beyond
the current boot.

FreeBSD convention treats `/var/run` as volatile. Some installations
leave `/var/run` on the same filesystem as the rest of `/var`, which
makes shared-memory writes more expensive and leaves stale region
files across reboots until the next module load truncates them. The
supported configuration mounts `/var/run` as tmpfs by adding this
line to `/etc/fstab`:

```
tmpfs /var/run tmpfs rw,mode=755 0 0
```

After editing `fstab`, either reboot or run `sudo mount /var/run` to
activate. Confirm with `mount | grep /var/run` (expect a `tmpfs on
/var/run` line). The inputfs verification protocol assumes this
configuration; running on a non-tmpfs `/var/run` is unsupported.

### PGSD kernel configuration

PGSD ships a kernel that omits the drivers inputfs supersedes: `hms`,
`hkbd`, `hgame`, `hcons`, `hsctrl`, `utouch`, `hpen`, and the
`hidmap` framework. Stock FreeBSD compiles `hms` and `hkbd`
statically into `GENERIC` and builds `.ko` modules for the rest,
which makes the HID transport layer attach the legacy drivers ahead
of inputfs at boot or on USB events. Running the inputfs verification
protocols on stock FreeBSD requires either booting the PGSD kernel or
moving the competing `.ko` files out of `/boot/kernel/` and
regenerating `linker.hints` (see AD-8 in `BACKLOG.md` for the durable
answer through `WITHOUT_MODULES` in `/etc/src.conf`).

---

## Multi-user deployment

Awase's substrate publication files default to mode `0600`, owned by
`root:wheel`, per ADR 0013
(`inputfs/docs/adr/0013-publication-permissions.md`). On a
single-user dev or bench system, no further configuration is needed:
all Awase daemons run as root by default, all consumers run through
`sudo`, and the substrate is uniformly accessible within that root
context.

On a multi-user system, operators relax the defaults through the
operating system rather than through Awase-specific configuration. Two
layers control the result.

**Kernel-side (`inputfs`).** Three sysctl tunables apply at module
load and at runtime:

```
sysctl hw.inputfs.dev_uid=0
sysctl hw.inputfs.dev_gid=$(getent group operator | cut -d: -f3)
sysctl hw.inputfs.dev_mode=0640
```

These can also live in `/boot/loader.conf` for boot-time defaults:

```
hw.inputfs.dev_uid=0
hw.inputfs.dev_gid=920
hw.inputfs.dev_mode=0640
```

The sysctls take effect for files created after the change.
Already-open files keep the attributes they were created with.
Reload the inputfs module to refresh.

**Userspace daemons.** The daemons run under s6 supervision (AD-20);
their process identity and umask are set in the s6 run scripts under
`s6/utf/<name>/run` (installed to `/var/service/utf/` by install.sh),
not through rc.conf user/group variables. install.sh creates the
`_semadraw` system user for the compositor's privilege separation. A
umask in a run script combines with the explicit modes Awase passes to
`createFile`: `umask 027` with `0o600` yields `0600`; `umask 037`
with `0o640` yields group-readable `0640`. Awase can never expose more
permission than its explicit mode, so the umask only ever restricts
further.

Add authorized consumers to the chosen group with `pw groupmod
operator -m <user>`. The user can then run `inputdump`, `chrono_dump`,
and similar diagnostic tools without `sudo`.

drawfs's cdev follows the same convention with parallel sysctls
(`hw.drawfs.dev_uid`, `hw.drawfs.dev_gid`, `hw.drawfs.dev_mode`).

---

## Build

Each subsystem builds on its own; the root `zig build` and `build.sh`
aggregate the userland subprojects, and `install.sh` performs the
full deployment (kernel modules, binaries, rc.d shims, and the s6
supervision tree) per `INSTALL.md`.

The canonical source location on a deployed system is
`/usr/local/src/Awase/`, aligned with `hier(7)`. See INSTALL.md Step 3
for the recommendation; developers cloning to a workspace folder need
no special handling, because all build scripts resolve paths relative
to themselves.

**drawfs** requires FreeBSD kernel sources:

```
cd drawfs
./build.sh install
./build.sh build
./build.sh load
./build.sh test
```

**semadraw**, **semasound**, and **chronofs** require Zig 0.15 or
newer:

```
cd semadraw  && zig build
cd semasound && zig build
cd chronofs  && zig build
```

**Run the stack.** On a deployed system the stack is supervised and
starts at boot; use the `service` interface (`service semasound
status`, `service semadraw restart`, and so on). The pre-AD-20
`start.sh` launcher was removed under F.6 (ADR 0029 Decision 4): the
service interface is the single startup story, per `INSTALL.md` Step
8.

**Run the terminal emulator by hand:**

```
sudo semadraw/zig-out/bin/semadraw-term            # auto-detects display size
sudo semadraw/zig-out/bin/semadraw-term --scale 2  # HiDPI
sudo semadraw/zig-out/bin/semadraw-term --scale 4  # 4K/5K
```

---

## Graphics Backends

| Backend | Use case | Requirements |
| --- | --- | --- |
| drawfs (EFI) | Bare-metal FreeBSD console | UEFI firmware, drawfs.ko loaded |
| X11 | FreeBSD with Xorg | libX11 |
| Vulkan | GPU-accelerated rendering | Vulkan driver |
| software | Testing and reference | None |
| DRM/KMS | Optional GPU modesetting | drm-kmod, build with DRAWFS_DRM_ENABLED |

The EFI framebuffer path works on any UEFI machine, whatever the GPU
age or driver availability, including hardware with no Vulkan support
and no working drm-kmod port.

---

## Status

| Component | Status |
| --- | --- |
| drawfs | Phase 1 complete. Phase 2 (EFI framebuffer) complete. DRM/KMS skeleton, opt-in only. |
| semadraw | drawfs backend operational. semadraw-term functional on bare metal and X11. |
| semasound | Complete (F.5, ADRs 0021/0024-0028): mixing, format adaptation and election, named targets, Phase 12 policy parity with reference-counted ducking, state publication, s6 supervision. Boot-started. Predecessor semaaud retired (F.6, ADR 0029). |
| semainput | `semainputd` daemon retired 2026-05-08 (AD-2a Phase 3). Only `libsemainput` remains, used by semadrawd. The Stage E cutover is done (see the inputfs row). |
| inputfs | Complete and in production (Stages A through E; AD-2 closed 2026-05-17; parser hardened by AD-9). The sole input path; no evdev in the tree. |
| audiofs | Stage F complete (F.0 through F.6, ADRs 0001-0029): class-matched PCI HDA driver, full output bring-up, data path, kernel clock writer, format negotiation. snd(4) removed in full (Option A). F.3.f (HDMI) deferred behind a Awase display capability. Complete and maintained under ADR 0030 (change classes K/B/P/T/R; production suite mode). |
| shared/ | Protocol constants, generator, event schema, session identity, clock interface: all complete. |
| chronofs | Complete. Audio-driven frame scheduler operational. |

**The substrate is complete and in service.** Input runs on inputfs
alone (AD-2 closed 2026-05-17), audio on audiofs and semasound alone
(F.6 closed 2026-06-05), and the clock on the audiofs kernel writer,
all of it supervised from boot. The open substrate-level audio work
proceeds under ADR 0030's maintained end-state; the open AD items are
in `BACKLOG.md`; and the upper layers (NDE, LT, the rest of SM) are
the next frontier, by choice of priority.

---

## License

BSD 2-Clause. See `LICENSE`.

Copyright (c) 2026 Pacific Geoscience Systems Development Foundation.
