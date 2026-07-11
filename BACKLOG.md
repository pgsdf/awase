# Awase Backlog

This is the **single, consolidated backlog** for the Unified Temporal
Fabric. It replaces the per-subsystem backlogs that previously lived at
`drawfs/drawfs-BACKLOG.md`, `semadraw/semadraw-BACKLOG.md`,
`semaaud/semaaud-BACKLOG.md`, `semainput/semainput-BACKLOG.md`,
`chronofs/chronofs-BACKLOG.md`, and `shared/shared-BACKLOG.md`.

Those files remain as short pointers to this one, so existing links and
references continue to resolve, but they are no longer the source of
truth for tasks. This file is.


**Split structure (2026-05-27 evening).** Closed and superseded
entries have been moved to `BACKLOG-history.md` to keep this
file focused on outstanding work. The split is mechanical:
every entry that was in BACKLOG.md before the split appears
in exactly one of the two files now. Cross-references to
closed entries are by name (e.g. "AD-39") and resolve to
the history file. Section headers (`##`) are preserved in
both files where they have at least one entry of the
relevant class.

**Second wave (2026-06-05, operator instruction).** The split
gains a second mechanism: the closed sub-milestone chronicle of a
still-open entry may move to a clearly marked historical record
entry in `BACKLOG-history.md`, leaving the active entry here,
compact, holding only live obligations and pointers. First
applied to AD-3 (the F-chain record).

---

## How to read this

Work is grouped by substrate, with each item numbered in its historical
ID (e.g. `DF-1`, `C-3`, `A-2`) so external references don't break.
Status is tracked per item:

- `[x] Done`: implemented, landed on `master`, acceptance criteria met.
- `[~] Fix applied, awaiting verification`: code change is in place but
  confirmation on the target host is pending. Flips to `[x]` once the
  relevant test run or smoke check comes back clean.
- `[ ] Open`: not yet started.
- `[ ] Deferred`: consciously postponed, with a note explaining why.

Priorities are **P0** (project-level invariant or blocker), **P1**
(near-term, directly unblocks downstream work), **P2** (valuable but
not on the critical path), or unset for items that don't need ranking.

All seven implementation waves (the original chronofs-anchored
dependency chain) are complete. The current theme is: **make DRM
strictly optional**, preserve the DRM-less default path as UTF's
unbreakable invariant while allowing opt-in DRM for users who want it.

---

## Project status

Moved here from `README.md` 2026-07-10 for reader clarity: the README
carries orientation, this file carries status. The component table
and the dated chronicle below are maintained here from now on.

### Component status

| Component | Status |
| --- | --- |
| drawfs | Phase 1 complete. Phase 2 (EFI framebuffer) complete. DRM/KMS skeleton, opt-in only. |
| semadraw | drawfs backend operational. semadraw-term functional on bare metal and X11. |
| semasound | Complete (F.5, ADRs 0021/0024-0028): mixing, format adaptation and election, named targets, Phase 12 policy parity with reference-counted ducking, state publication, s6 supervision. Boot-started. Predecessor semaaud retired (F.6, ADR 0029). |
| semainput | `semainputd` daemon retired 2026-05-08 (AD-2a Phase 3). Only `libsemainput` remains, used by semadrawd. The Stage E cutover is done (see the inputfs row). |
| inputfs | Complete and in production (Stages A through E; AD-2 closed 2026-05-17; parser hardened by AD-9). The sole input path; no evdev in the tree. |
| audiofs | Stage F complete (F.0 through F.6, ADRs 0001-0029): class-matched PCI HDA driver, full output bring-up, data path, kernel clock writer, format negotiation. snd(4) removed in full (Option A). F.3.f (HDMI) deferred behind an Awase display capability. Complete and maintained under ADR 0030 (change classes K/B/P/T/R; production suite mode). |
| shared/ | Protocol constants, generator, event schema, session identity, clock interface: all complete. |
| chronofs | Complete. Audio-driven frame scheduler operational. |

**The substrate is complete and in service.** Input runs on inputfs
alone (AD-2 closed 2026-05-17), audio on audiofs and semasound alone
(F.6 closed 2026-06-05), and the clock on the audiofs kernel writer,
all of it supervised from boot. The open substrate-level audio work
proceeds under ADR 0030's maintained end-state; the open AD items are
tracked below in this file; and the upper layers (NDE, LT, the rest of SM) are
the next frontier, by choice of priority. The installation and
packaging path is moving under project ADR 0002 to a published
artifact contract converging on Axiom: milestone 1 (kernel
separation) landed and was bench-verified 2026-07-10; the remaining
milestones are tracked under the ADR 0002 entry below.

### Current state (2026-07-10)

What is built and verified:

- The **installation architecture** is moving under ADR 0002 (ratified
  2026-07-10) to a producer/consumer split joined by a published
  artifact contract. Milestone 1 is landed and bench-verified:
  `install.sh` installs the userland only and detects the kernel
  state; the PGSD kernel is built and installed separately per
  `pgsd-kernel/KERNEL-RECIPE.md`; and the bench runs the pinned PGSD
  kernel, its commit hash visible in `uname`. Milestone 2 (the Awase
  build staging Axiom-format artifact sets with per-file inventory)
  is next.
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
  systems. See the AD-3 entry below.
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
(HDMI) stays a live deferred entry. The other open AD items are
tracked below; `BACKLOG-history.md` holds the completed chronicle.

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
Management` and the semadraw D-10 and D-11 entries below.

---

## Current theme: make DRM strictly optional

The goal is that the DRM-less swap path remains the unbreakable default
and that DRM/KMS support is a strictly optional add-on. A user running
`sh configure.sh` and accepting defaults must produce a `drawfs.ko`
with no DRM references, no `drm-kmod` build dependency, and no
`drm-kmod` load dependency.

### Non-goals

- Making DRM the default. It will never be the default.
- Detecting drm-kmod automatically. Autodetection leaks the opinion
  that "DRM is better" into the build; it is not.
- Removing `drawfs_drm.c` or the kernel-side `#ifdef
  DRAWFS_DRM_ENABLED` gates. They are correct already.
- Surfacing DRM backend selection through `semadrawd` CLI. `semadrawd
  -b drawfs` is agnostic to the kernel backend.

---

## Project-level invariants

These hold across all changes. Any future work that would break one
needs its own backlog item first, documenting why the invariant is
changing.

1. `sh configure.sh` with all defaults → swap-only `drawfs.ko`.
2. `drm-kmod` is never a build-time or load-time hard dependency.
3. `hw.drawfs.backend` defaults to `"swap"` at module load.
4. DRM init failure at module load falls back to swap, never panics,
   never prevents load.
5. Renaming `DRAWFS_DRM_ENABLED` requires coordinating with every
   `#ifdef` in `drawfs.c`, `drawfs_drm.c`, and both Makefiles.
6. `UTF_OS` detection is informational only. Any future use that
   branches build behavior on it must be justified by a concrete,
   observable divergence on the FreeBSD target, not a speculation.
7. UTF depends only on code written with UTF's guarantees in mind.
   External dependencies are either replaced by UTF-owned code or
   explicitly accepted as named platform-transport dependencies.
   See `docs/AWASE_ARCHITECTURAL_DISCIPLINE.md` for the accepted list
   and the three postures (Replace / Accept / Remove).

---

## `drawfs`: kernel spatial substrate

`/dev/draw` character device, surface lifecycle, mmap-backed pixel
buffers, framed binary protocol, input event injection.

### `[~]` DF-6: DRM backend runtime wiring  *(IMPLEMENTED 2026-06-07 per ADR 0002, operator-ratified; runtime verification BLOCKED on DRM/KMS hardware)*

**Tracks**: `drawfs/sys/dev/drawfs/drawfs.c`
(`drawfs_reply_surface_present`),
`drawfs/sys/dev/drawfs/drawfs_drm.c`
(`drawfs_drm_surface_present`),
`docs/DF4_VERIFICATION.md` (AD-18.7 fix design).

DF-3 closed as "Done, skeleton": `drawfs_drm.c` contains a full
DRM/KMS implementation (connector enumeration, mode set, dumb
buffer allocation, page flip), but the SURFACE_PRESENT handler
in `drawfs.c` does not dispatch into it. `grep` finds no
callers of `drawfs_drm_surface_present`. DF-6 connects the
two so that, when `hw.drawfs.backend=drm` is selected on
hardware with a matching KMS driver, a client's SURFACE_PRESENT
actually drives a page flip.

**Scope**:

  - Add a backend-dispatch step in `drawfs_reply_surface_present`
    (`drawfs.c` line ~459, after the surface lookup succeeds)
    that, when the active display is DRM-backed and the surface
    is in a state suitable for present, calls
    `drawfs_drm_surface_present(dd, surf, damage, damage_count)`.
  - Resolve the locking-order question for the call: the
    handler currently holds `s->lock` over the lookup but
    not over the reply send; the DRM backend takes
    `dd->drm_mtx`. The two locks are unrelated by ordering
    convention but the call must not nest `s->lock` under
    `dd->drm_mtx` or vice versa in a way that creates a
    new WITNESS warning.
  - Apply the AD-18.7 fix in `drawfs_drm_surface_present`:
    refactor the function to capture flip parameters under
    `dd->drm_mtx`, release the lock, call
    `drm_ioctl_kern(DRM_IOCTL_MODE_PAGE_FLIP, ...)` unlocked,
    re-acquire the lock to install `flip_pending = 1` and
    perform the front/back swap. Same shape as AD-18.2
    (vm_pager_allocate refactor) and AD-18.3/4 (M_WAITOK
    malloc refactor): capture, release, slow call, re-acquire,
    install or yield.
  - Page-flip completion: today `dd->flip_pending` is set
    but nothing clears it. A kthread reading from the DRM
    event queue and toggling the flag on
    `DRM_EVENT_FLIP_COMPLETE` is the production answer.
    Initial DF-6 may set up the kthread skeleton without
    requiring complete event-queue handling.
  - Bench verification under PGSD-DEBUG: WITNESS clean on
    sustained present workload, no leak in
    `vmobj_allocs == vmobj_deallocs`,
    `flip_pending` clears between presents (when the kthread
    lands), front/back pointers stay consistent across many
    cycles.

**Hardware dependency**: DF-6 cannot be runtime-verified
without DRM-capable hardware running a FreeBSD KMS driver
(`amdgpu`, `i915kms`, `nvidiakms`, `radeonkms`). The PGSD
test machines today use `efifb` only. DF-6 is therefore
filed but **not scheduled** until matching hardware is
available or a virtualised KMS environment is set up
(VirtualBox VGA does not present a KMS DRM device;
qemu's `virtio-gpu` does).

**Discharges**: AD-18.7. The fix design for that locking
bug is captured in the AD-18 entry and applies cleanly
in this work.

**Filing note**: DF-6 was filed 2026-05-21 during a status
audit that identified an inconsistency in BACKLOG: AD-18.7
was tagged "deferred to DF-3" but DF-3 had closed as
"skeleton" without the wiring AD-18.7 was waiting for.
DF-6 is the missing piece that makes the dependency chain
honest. AD-18.7's deferral target was re-tagged from DF-3
to DF-6 in the same commit.

---

#### Implementation (2026-06-07, ADR 0002, D1 through D6)

Reading the tree first showed the scope was larger than "connect the
two functions": drawfs_drm_display_open had no callers, the session
struct held no display, and only the backend sysctl existed, the
display lifecycle was entirely absent. Implemented across four files:

  - drawfs.c: a single global g_drm_display guarded by a dedicated
    drawfs_drm_display_mtx (D1), opened lazily on the first
    SET_DISPLAY while the backend is "drm" (outside s->lock, since
    open does DRM ioctls), and closed at MOD_UNLOAD. The
    SURFACE_PRESENT success path (D2) gates on backend=drm and a
    non-NULL display, re-finds the surface under a held s->lock via
    drawfs_surface_lookup_locked (D3, keeping surf and its vm_object
    alive), and calls the DRM present inside that hold, establishing
    the documented order s->lock -> dd->drm_mtx. The locking-model
    comment records the order. Swap/efifb behaviour is byte-identical
    (every new path is gated).
  - drawfs_drm.c: the AD-18.7 fix (D4), refactoring
    drawfs_drm_surface_present to claim flip_pending under drm_mtx,
    drop the lock, issue drm_ioctl_kern(PAGE_FLIP) unlocked,
    re-acquire, and swap on success or roll the claim back on
    failure; and the completion-kthread skeleton (D5): lifecycle
    wired and joinable (create at open, stop-and-poll join at close
    via completion_run states 1/0/2), with the DRM event-queue read
    a documented TODO. Damage stays full-surface (D6).
  - drawfs_drm.h: the kthread fields and a struct proc forward
    declaration.

All four files are brace-balanced and dash-clean (pre-existing em
dashes cleaned on contact in drawfs.c and drawfs_drm.c). The default
build links without drawfs_drm.o (swap-only); the DRM code is under
DRAWFS_DRM_ENABLED. The container cannot compile a kernel module;
the operator's build is the syntax arbiter.

VERIFICATION BLOCKED on DRM/KMS-capable hardware, the intended
validation target (the PGSD machines run efifb only). Pre-merge
gate verifiable now: backend=swap behaviour byte-identical to
pre-DF-6. PASSED 2026-06-07: the default (swap-only) build
compiled clean, confirming both the regression gate and that the
DRAWFS_DRM_ENABLED guards are hygienic (no DF-6 code leaked into
the always-compiled path; drawfs_drm.o is not linked by default).
The DRM translation unit was then compiler-checked: a
DRAWFS_DRM=true build (with drm-kmod headers) compiled clean on
2026-06-07, exercising all of the new DRM C, the global display and
its mutex, the lazy open, the gated dispatch and
drawfs_surface_lookup_locked use, the AD-18.7 claim/drop/ioctl/
re-acquire refactor, and the completion kthread (kproc_create
shape, struct proc field, pause/kproc_exit). Every static check
DF-6 can pass has passed (both build configurations clean). The
SOLE remaining gate is runtime on DRM/KMS hardware: WITNESS clean
under sustained present, vmobj alloc/dealloc balance, flip_pending
clearing once the D5 event-queue read lands, and front/back
consistency. Full validation (WITNESS clean under sustained present,
vmobj alloc/dealloc balance, flip_pending clearing once the D5 event
read lands, front/back consistency) is owed on hardware and DF-6 is
not considered validated until then.

## `semadraw`: semantic rendering substrate

### `[x]` SDCS-1: fill, paint sources, and path clipping completion  *(Closed 2026-06-14, operator-ratified; ADR 0014 program)*

**ADR 0014 program closed. All four stages landed, passed golden-image
verification, and are now part of the baseline SDCS feature set.**

The v0.1 SDCS opcode set (ADR 0004 scope) stroked paths but could not
fill them, had no paint source beyond inline RGBA, and clipped only to
rectangles. ADR 0014 (program ADR, 2026-06-13) staged the completion of
the three in-scope capabilities ADR 0004 enumerated but v0.1 left
unimplemented: path fill with winding rules, gradient and pattern paint
sources, and arbitrary path clipping. Each stage landed under its own
implementation ADR (ADR-before-code per stage); the software reference
renderer (`sdcs_replay.zig`, the golden oracle per ADR 0002) and golden
tests were the closure gate.

Stages and the opcodes they added to the baseline:

- **Stage A** (ADR 0015): path fill, `FILL_PATH` 0x0019, nonzero and
  even-odd winding.
- **Stage B1** (ADR 0016): gradient sources, `SET_SOURCE_LINEAR_GRADIENT`
  0x0009, `SET_SOURCE_RADIAL_GRADIENT` 0x000A, and `SET_SOURCE_NONE`
  0x0008 (reset to inline RGBA).
- **Stage B2** (ADR 0017): pattern (surface) source, `SET_SOURCE_PATTERN`
  0x000B.
- **Stage C** (ADR 0018): arbitrary path clipping, `SET_CLIP_PATH`
  0x000C. Closes the ADR 0014 program.

Closure criteria met: `sudo sh tests/run.sh` green end-to-end on
pgsd-bare-metal across all stages, including the Stage C clip suite (all
ten ADR 0018 section-8 invariants) and the cross-platform scene hash
(sandbox replay byte-identical to bare metal; pure-Zig trig reproduces
bit-for-bit). The C-1 byte-identity invariant (rect fills under a path
clip match the path-fill rasterizer sample-for-sample) holds across the
clip work. Downstream: LT-1 names "SDCS stable" as a dependency; that is
now met for the 2D drawing surface.

The window-manager-client additions below come from the NDE-1
substrate validation (`semadraw/docs/WM_CLIENT_CONTRACT.md`) against
NDE DESIGN.md section 3.2. Each is a general privileged-client
capability built on the existing `SEMADRAW_PRIVILEGED_UID` mechanism
(the same pattern as `handleRemoteSetZOrder`), not an NDE-specific
path: NDE is simply the process running as the configured privileged
uid, and it consumes these only through the documented WM-client
contract, never through semadraw internals. Project decision
(2026-06-08): NDE remains a separate repository
(github.com/pgsdf/NDE); the repository boundary is not blurred and no
privileged NDE-specific access path is introduced. Each item is ADR
before code.

### `[x]` D-7: privileged set-focus message  *(Closed 2026-06-26, Small, P1; NDE-1 Milestone 1 focus blocker cleared)*

The Surface Manager must assign keyboard focus (NDE policy per
DESIGN.md sections 3.2 and 3.3). The focus-region writer already
exists (`FocusWriter.setKeyboardFocus`) but has no daemon caller, so
keyboard focus is not driven today. Add a privileged client-to-daemon
set-focus message and a handler that calls `setKeyboardFocus` for the
privileged client, taking effect at a well-defined point (not
mid-frame) per DESIGN.md section 5 determinism. This is the single
substrate addition that unblocks NDE-1 (NDE ROADMAP Milestone 1 basic
window policy: focus, raise, close; raise is `set_z_order` and close
is `destroy_surface`, both already provided). ADR 0011 (Accepted
2026-06-08): set-focus is `set_focus = 0x0034` keyed by surface,
resolved to the owning session, privileged-gated, deterministic; the
D5 `focus_changed = 0x9003` event is included, and a focus-validity
invariant (D7) guarantees the daemon never publishes a focus without a
live surface (cleared on destroy and disconnect). Bench: the privileged
client sets focus to each of two surfaces owned by distinct clients;
`inputfs` routes keyboard input to the focused client; a non-privileged
client is refused; destroy and disconnect clear focus to `NO_FOCUS`.

**Progress (2026-06-14, scoping and prerequisite; D-7 paused).** ADR 0011
accepted. Protocol slots verified free in the semadraw client namespace
(`set_focus` 0x0034 in requests, `focus_changed` 0x9003 in events; the
earlier apparent 0x9003 collision was a different protocol section).
Implementation scoped into four increments: (1) protocol constants + wire
structs + ser/deser tests; (2) focus-region ownership and lifecycle; (3)
`set_focus` handler + privilege gate + surface→session resolution + region
publication; (4) `focus_changed` events + the D7 validity invariant +
integration bench.

FocusWriter ownership investigation completed: `FocusWriter`,
`setKeyboardFocus`, and `setSurfaceMap` are referenced only in
`shared/src/input.zig` and have never had a daemon caller. INPUT_FOCUS.md
and inputfs ADR 0003 both name the compositor (semadrawd) as the sole
writer and owner of `/var/run/sema/input/focus`. Semadrawd is therefore
confirmed as the intended sole writer; the work is simply unlanded.
Focus-region publication is identified as a prerequisite capability
broader than set_focus (it also owns the pointer-routing `surface_map` and
the seqlock discipline), handled as its own increment and likely its own
brief ADR. `forwardKeyEvents()` (the existing top-visible-surface key
delivery) is intentionally out of scope: D-7 is focus-region publication
only, and unifying the two focus models would need its own ADR.

D-7 is paused pending that prerequisite work and a protocol-constants
reconciliation (AD-54) that had to land before increment 1 could
regenerate cleanly.

**Completed (2026-06-26).** All four increments plus the client library
landed and bench-verified (zig build and zig build test green on
bare-metal-test-bench). What landed: (1) set_focus 0x0034 and
focus_changed 0x9003 constants with SetFocusMsg/FocusChangedMsg wire
structs and tests; (2) semadrawd owns the FocusWriter, created at startup
(mandatory, per INPUT_FOCUS.md lifecycle); (3) handleSetFocus and
handleRemoteSetFocus, gated on isPrivileged (not per-surface ownership),
resolving surface to owning session and publishing keyboard focus through
the seqlock, recording focused_surface; (4) focus_changed emission with
the policy that destroy notifies the surviving owner while disconnect
clears silently, and the D7 invariant enforced on three paths (set_focus,
surface-destroy, client-disconnect) with the clear running before
removeClientSurfaces frees the records. The client library exposes
setFocus (local and remote) and decodes focus_changed.

The AD-54 prerequisite was already closed; the focus-region writer
prerequisite turned out to be already built in shared/src/input.zig, so
increment 2 was wiring rather than new construction.

Verification is layered (see semadraw/docs/D7-IMPLEMENTATION-SCOPE.md,
"Verification boundary"): the focus writer/reader ABI, the privilege
predicate, and surface ownership are unit-tested; handler composition and
end-to-end keyboard routing are deferred to SM-TEST-1 (daemon testability
plus a reusable IPC integration harness), because Daemon couples
construction to OS resources and routing is the semadrawd-to-inputfs
contract rather than D-7 logic. The full two-client acceptance bench runs
once SM-TEST-1 exists; D-7's own responsibilities are complete and
verified at the primitive level.

### `[ ]` D-8: privileged pointer-grab message  *(Open 2026-06-08, Small, P2; serves fuller section 3.2, after D-7)*

Popups need a pointer grab (route pointer input to the grabbing
surface until released). The writer exists
(`FocusWriter.setPointerGrab`, used today only to reset to NO_GRAB);
`inputfs` already reads the focus region. Add a privileged
grab-and-release message and handler, with `inputfs` honoring the
grab in routing. Not required for NDE-1; serves NDE Milestone 2 and
beyond. ADR before code.

### `[ ]` D-9: subsurface semantics  *(Open 2026-06-08, Large, P2; serves fuller section 3.2, after D-7)*

DESIGN.md section 3.2 requires subsurfaces; semadraw has none today
(`create_surface` carries no parent, the registry has no parent-child
relationship). A subsurface must move atomically with its parent and
clip to it; approximating with independent surfaces and `set_position`
is racy and would violate section 5 determinism. Genuine compositor
work: a parent reference at create time (or a set-parent message),
atomic positioning relative to the parent, and clip-to-parent in
composition. The substantial one; warrants its own ADR. Not required
for NDE-1; serves NDE Milestone 2 and beyond. ADR before code.

### `[ ]` D-10: compositor-enforced session-lock mode  *(Open 2026-06-09, Large, P1; secure-lock primitive for SM-2/SM-3)*

From SM-2 (ADR 0010 D3) and SM-3 (ADR 0009): a secure screen lock needs
a compositor-enforced lock state, which semadraw lacks. z-order, the
proposed set-focus (D-7), and grab (D-8) do not substitute; they are
defeatable by the parties a lock must defend against. The
ext-session-lock analogue: an authorized lock client requests lock;
while locked, semadrawd presents only that client's surface and routes
all input to it, ignoring every other surface's presentation and input
and overriding window-manager policy, until the client authenticates
and requests unlock. The lock client is pgsd-sessiond (root, the
session authenticator), so lock authority is distinct from the
window-manager privilege (SEMADRAW_PRIVILEGED_UID): the lock must be
enforceable over the WM and therefore cannot route through WM
privilege. Security-critical and warrants its own ADR, in which the
lock-client authorization model is decided. Gates the secure SM-2 under
the secure-environment mandate. ADR: `semadraw/docs/adr/0012-session-lock-mode.md`
(Accepted 2026-06-09). Protocol additions landed (Stage 1a): `session_lock`
0x0035, `session_unlock` 0x0036, `session_locked` 0x9004, and
`session_unlocked` 0x9005 in `protocol.zig`. Code still owed (Stage 1b
onward, paused pending a larger time block): focus-region lock field,
semadrawd LOCKED state machine, inputfs precedence, bench.

## Deferred

### `[ ]` SM-TEST-1: daemon testability and IPC integration harness  *(Deferred 2026-06-26, opened by D-7; serves the window-management line, not D-7 alone)*

A reusable way to exercise semadrawd end-to-end with connected clients,
and the daemon refactor that makes it possible. Opened by D-7 (privileged
set-focus), whose handler composition and end-to-end routing could not be
unit-tested because Daemon couples construction to operating-system
resources (it binds a Unix socket and mmaps the focus region in init), so
it cannot be instantiated in a unit test. D-7 verified its primitives
(focus writer/reader contract, privilege predicate, surface ownership) at
the unit level and recorded the boundary; this item covers the rest.

Two related pieces, intentionally NOT built for D-7 alone:

  - Daemon testability: separate resource acquisition from the testable
    core (for example a constructor that does not bind real OS resources,
    or splitting socket/focus-region setup from the dispatch logic), so
    handler composition (gate plus resolve plus write wired together) can
    be tested without real sockets and files.
  - IPC integration harness: start the daemon and connect multiple
    distinct clients (including a privileged one), drive protocol
    messages, and assert externally observable behavior. This would let
    D-7's full acceptance bench run automatically (two surfaces from
    distinct clients, focus routing, clear, privilege refusal, the D7
    invariant on destroy and disconnect) and would serve subsequent
    window-management work (NDE-1, input routing, compositor behavior)
    rather than being one-off D-7 scaffolding.

Rationale for deferral: building either solely to satisfy D-7 would
expand "implement privileged keyboard focus" into "design an IPC
integration framework." Treated as separate engineering work, both pay
off across future features. See semadraw/docs/D7-IMPLEMENTATION-SCOPE.md,
"Verification boundary."

### `[~]` B3.3: Damage / partial-update swap-path implementation  *(Pass 1 in tree; Pass 2 and Pass 3 not landed. Status corrected 2026-05-27 evening; previously claimed "Done" in error.)*

Three-pass implementation of `DRAWFS_REQ_SURFACE_PRESENT_REGION` in
the swap-backed kernel path. Status accurate as of the
2026-05-27 correction; ground truth is the source tree, not the
previous claim.

1. **Pass 1** (validator): **landed.** Pure function
   `drawfs_req_surface_present_region_validate` in `drawfs_frame.c`
   enforcing the full error table from the design doc. 15 userspace
   unit tests pass; kernel compile clean on the FreeBSD target.
   The validator's own comment at `drawfs_frame.c:77` is explicit
   that the work it does not do ("does not consult session state,
   does not look up the surface, does not clamp rects to surface
   bounds, and does not allocate") is deferred to Pass 2.
2. **Pass 2** (dispatch + coalescing + sysctl): **not landed.**
   The intended handler `drawfs_reply_surface_present_region` in
   `drawfs.c` does not exist; the dispatch switch at
   `drawfs.c:1400-1444` has no case for
   `DRAWFS_REQ_SURFACE_PRESENT_REGION` (only the original
   `DRAWFS_REQ_SURFACE_PRESENT`). No `hw.drawfs.region_coalesce_threshold`
   sysctl is registered (verified by grep over
   `drawfs/sys/dev/drawfs/*.c`; the only sysctls in the module are
   the dev_uid/gid/mode, mmap, evq, surface-budget, and vmobj-debug
   ones, plus `hw.drawfs.coalesce_events` from earlier work). A
   non-PGSD client issuing `DRAWFS_REQ_SURFACE_PRESENT_REGION` today
   would hit the dispatch default arm and receive `ERR_UNSUPPORTED_CAP`,
   which is consistent with the design doc's backward-compatibility
   section but is NOT what "Done" would mean.
3. **Pass 3** (integration tests): **partially landed (test file
   only; no implementation under test).**
   `drawfs/tests/test_surface_present_region.py` exists with the
   18 test cases described, but with Pass 2's handler absent the
   tests cannot exercise dispatch, clamping, coalescing, or the
   N=1-full-surface equivalence invariant against a real server.
   The test file is checked in but is not bench-verified against
   landed code.

Corroborating evidence for the corrected status: BACKLOG.md line
282-283 (in a separate entry, written later) already notes "the
validator added in pass 1 still has no callers" - that statement
contradicts the "Done" claim on this entry and was correct.
This entry was the stale one.

How the misclaim happened (best reconstruction without git
history for these commits): the entry appears to have been
written speculatively, describing what B3.3 *would* be when all
three passes landed, then marked `[x]` Done before Pass 2 and
Pass 3 actually shipped. The validator's defer-to-Pass-2 comment
was preserved through whatever sync brought the working tree to
its current state, but the dispatch+handler+sysctl were not.

Implementation impact going forward: AD-43.3b's plan (paused
at 2026-05-27 evening, awaiting Scenario 1 vs Scenario 3
decision per the AD-43 evening update) depends on Pass 2 + Pass 3
actually landing. The work estimated by the original B3.3 entry
("18 userspace unit tests on clamp and threshold arithmetic
pass; kernel compile clean, sysctl exposed on target") is still
ahead, not behind. Effort estimate: small-to-medium kernel-side
work plus a re-bench of the existing Python test fixture.

Design choices documented in
`drawfs/docs/DESIGN-surface-present-region.md`:
sum-of-areas coalescing (not true union), single event type
(`EVT_SURFACE_PRESENTED_REGION`) regardless of collapse, no
cross-request region-event coalescing.

### `[ ]` B3.4-B3.5: Damage / partial-update: DRM path and semadraw emitter  *(Deferred, P2; depends: B3.3)*

With the swap path complete (B3.3), the remaining implementation is:

1. **B3.4**: DRM path. `drmModeDirtyFB` when the kernel DRM driver
   supports it, full-present fallback otherwise. Only meaningful
   with `DRAWFS_DRM_ENABLED`. Requires access to a drm-kmod-enabled
   FreeBSD 15 host to exercise end-to-end.
2. **B3.5**: semadraw emitter. Extend
   `semadraw/src/backend/drawfs.zig` to emit region presents when
   the compositor's damage tracker produces a bounded rect set.
   Requires B3.4 to be landed first for end-to-end testing.

**Non-goals** and **acceptance criteria** are documented in full at
`drawfs/docs/DESIGN-surface-present-region.md`.

---

### `[ ]` AD-3/F.3.f: audiofs HDMI bring-up  *(Deferred 2026-06-01; blocked on a UTF-provided display capability, not on hardware and not on audiofs)*

HDMI audio is the GPU's HDA function: it reports pin presence,
exposes an ELD, and clocks audio only after the display side has
detected the sink, programmed the mode, lit the link, and enabled
the audio path. That coordination is what drm-kmod provides and
PGSD will not use; the UTF-native display capability F.3.f waits
on is a separate, yet-to-be-scoped effort (distinct from DF-6,
which targets the existing drm-kmod KMS path). Scope when
unblocked: ADR 0011's F.3.f items (presence detection, audio
infoframes, stream verification), verified on a machine with a
working HDMI/DP output (pgsd-bare-metal cannot drive HDMI audio
end to end). Governing terms: ADR 0030 (the maintained AD-3
end-state; HDMI on the confirmed target stays at full guarantee),
ADR 0008 section 3a (chipset scope and fences). History: the
archived AD-3 entry and F-chain record in BACKLOG-history.md.

## Long-term: Retained Layer Model on Awase

These items represent the path toward a retained-mode layer and
animation model above SDCS. They are long-term architectural goals,
not near-term sprint items.

**Reframing (2026-06-12, operator-ratified).** This section
previously targeted a native GNUstep/AppKit display stack, a Quartz
equivalent requiring no X11. That goal is retired: NDE is
semantic-native, and its vocabulary is defined by NDE's versioned
contracts, not by an imported toolkit's object model. AppKit's
semantics are toolkit-private and opaque to the system, which
contradicts the substrate's thesis that intent is visible to the
system (SDCS expresses drawing intent; semainput emits semantic
gestures; chronofs makes time addressable). LT-1 and LT-2 stand on
their own as substrate mechanism, a retained layer tree and a
chronofs-driven animation engine, and now serve the semantic NDE
rather than a GNUstep endpoint. LT-3 is retired below. Compatibility
for existing application stacks, if ever wanted, enters as a fenced
tenant alongside NDE-5, under its own ADR, and must not shape the
native semantic vocabulary.

**Background.** UTF already provides the lower half of this stack:
drawfs owns the framebuffer (`/dev/draw`), semadrawd is the compositor,
SDCS is the drawing command stream, and the EFI framebuffer backend
means the stack runs on any UEFI machine without a GPU driver. What is
missing is the retained-mode layer model above SDCS.

### `[ ]` LT-1: Layer Tree Protocol on top of SDCS  *(Open, Large)*

**Depends on**: SDCS stable, semadrawd compositor operational

Surfaces become layers with transform, opacity, clip, and z-order
properties. Clients describe a retained scene graph rather than pushing
raw pixel commands each frame. semadrawd composites the layer tree
rather than blitting each surface independently.

**Scope (2026-06-13, NDE semantic design Revision 2, decision 2 /
correction A).** LT-1 is presentation mechanism only: transform,
opacity, clip, z-order. The semantic tree is unbundled from LT-1 and
lives as a separate versioned wire format and library in `shared/`,
terminating at NDE; the two are never fused. Revision 1 had fused two
structures with different shapes, cadences, and owners, and that was
withdrawn as a design error. LT-1 carries no typed semantic properties
or transactions.

Key design points:

- Extend the semadraw IPC protocol with `SET_LAYER_TRANSFORM`,
  `SET_LAYER_OPACITY`, `SET_LAYER_CLIP` messages
- semadrawd maintains a retained layer tree per client session
- Only damaged layers are re-rendered each frame
- Layer properties are animatable (see LT-2)
- Implementation lives in `semadraw/src/daemon/layer_tree.zig`

### `[ ]` LT-2: Animation Engine driven by the chronofs Clock  *(Open, Large)*

**Depends on**: LT-1, chronofs `ChronofsClockSource` wired into
semadrawd frame scheduler

An animation engine that interpolates layer properties between frames,
driven by the chronofs audio-hardware clock. This is the UTF equivalent
of Core Animation's display link and implicit transaction model.

Key design points:

- Animations are submitted as `(property, from, to, duration, curve)`
  tuples via the semadraw IPC protocol
- The frame scheduler calls `nextFrameTarget()` from chronofs to
  determine the next sample-aligned frame boundary
- Property values are interpolated at each frame boundary and applied
  to the layer tree before compositing
- Animations are drift-free by construction, clocked against audio
  hardware rather than wall time, eliminating audio/visual skew
- Easing curves: linear, ease-in, ease-out, ease-in-out, spring

### `[x]` LT-3: GNUstep Backend targeting semadraw instead of X11  *(RETIRED 2026-06-12, operator-ratified; never started, no code removed)*

Retired under the semantic-NDE ratification of 2026-06-12. NDE is a
semantic solution; a GNUstep/AppKit backend as a first-class citizen
contradicts that charter, since AppKit's meaning (responder chains,
key windows, control roles) is private to the toolkit and opaque to
the system. No code existed; nothing is removed. If GNUstep
compatibility is ever wanted, it returns as a fenced compatibility
tenant alongside NDE-5, under a new ADR, and must not influence the
native semantic vocabulary. The NDE charter and DESIGN.md revision
recording the semantic-native commitment is owed in the NDE
repository. The original entry follows for the record.

**Depends on**: LT-1, LT-2; libs-opal and libs-quartzcore in GNUstep
upstream

A GNUstep display backend (`back-semadraw`) that implements
`GSDisplayServer` against semadraw rather than X11. This allows the
full GNUstep/AppKit application stack to run natively on UTF without
X11 as an intermediary, on any UEFI machine including older hardware
with no GPU driver.

Key design points:

- `back-semadraw` implements `GSDisplayServer` using the semadraw
  client library (`libsemadraw`)
- Opal (2D drawing, PDF model) maps its drawing operations to SDCS
  commands
- QuartzCore (layer compositing, Core Animation) maps to the LT-1
  layer tree protocol and LT-2 animation engine
- Applications run unmodified on bare metal FreeBSD via any UTF
  backend: EFI framebuffer (any UEFI machine, no GPU driver required),
  Vulkan (GPU-accelerated), or X11 (compatibility mode)
- Makes UTF the FreeBSD analog of Quartz Compositor on macOS, with
  GNUstep as the application framework above it

---

## NDE: Native Desktop Environment

NDE is the policy and user experience layer above semadraw and drawfs.
It lives at https://github.com/pgsdf/NDE and defines versioned contracts
for windowing policy, input, settings, session management, and
compatibility. NDE does not redefine kernel graphics transport or
semantic rendering; those remain the responsibility of drawfs and
semadraw respectively.

NDE Milestone 0 (vocabulary freeze, charter, design specification,
repository skeleton) is complete. The items below correspond to NDE
Milestone 1 (substrate validation) and beyond.

**Relationship to LT-1 and LT-2.** NDE is usable today without
the long-term retained-layer items; it can manage semadraw-term
sessions and basic SDCS applications using the current immediate-mode
rendering model. LT-1 (layer tree) would make NDE's own UI smoother
and enable proper animated transitions; LT-2 (animation engine) gives
those transitions the chronofs clock. LT-3 (GNUstep backend) was
retired 2026-06-12 under the semantic-NDE ratification; toolkit
compatibility, if ever wanted, enters as a fenced tenant alongside
NDE-5.

### `[ ]` NDE-1: Surface Manager  *(Open, Medium)*

**Depends on**: semadrawd compositor operational (done)
**Tracks**: NDE Milestone 1, substrate validation

Implement the NDE windowing policy contract (DESIGN.md §3.2): toplevel
surfaces, popups, stacking rules, focus transitions, server-side
decorations. NDE acts as a privileged semadraw client that manages
surface z-order and focus on behalf of all other clients.

Key design points:

- NDE registers with semadrawd as the window manager client
- Surface stacking is controlled via `SET_Z_ORDER` messages
- Focus ownership follows DESIGN.md §3.2 semantics
- Server-side decorations rendered as NDE-owned surfaces overlaid on
  application surfaces

**Substrate validation (2026-06-08).** semadraw's window-manager-
client contract is documented and validated in
`semadraw/docs/WM_CLIENT_CONTRACT.md`. Provided by the existing
protocol: the privileged WM client (by uid, ADR 0006 section 3),
stacking and z-order including cross-client reorder via
`handleRemoteSetZOrder`, position, visibility, and server-side
decorations as NDE-owned overlay surfaces. NDE DESIGN.md section 3.2
(received 2026-06-08) confirms the gaps and adds a third: focus
transitions and grabs are NDE policy, and subsurfaces are required.
Three semadraw substrate additions follow, each ADR before code,
proposed and awaiting operator ratification to open as items: (1) a
privileged set-focus message and handler (FocusWriter.setKeyboardFocus
already exists, has no daemon caller; small); (2) a privileged grab
and release message and handler with inputfs honoring the grab
(FocusWriter.setPointerGrab exists; small); (3) subsurface semantics,
parent-child surfaces with atomic positioning and clip-to-parent (no
substrate today; the substantial one, argued by section 5
determinism). Toplevel-versus-popup role labels stay NDE-tracked with
no protocol change. The conformant Surface Manager design proper lives
in the NDE repo against section 3.2, consuming the three additions.

**Milestone sequencing (NDE ROADMAP, 2026-06-08).** NDE's ROADMAP
scopes Milestone 1 (which this entry tracks) as basic window policy:
focus, raise, close. Raise is `set_z_order` and close is
`destroy_surface`, both already provided, so only Gap 1 (set-focus)
blocks NDE-1. Gap 2 (grabs and popups) and Gap 3 (subsurfaces) serve
the fuller section 3.2 policy at NDE Milestone 2 and beyond and are
sequenced after NDE-1. NDE-1's critical substrate path is therefore
the single small set-focus addition.

**Project decision (2026-06-08, ratified).** NDE remains a separate
repository (github.com/pgsdf/NDE). NDE interacts with semadraw only
through the documented WM-client contract
(`semadraw/docs/WM_CLIENT_CONTRACT.md`) and does not depend on
semadraw internals. The substrate additions NDE needs (D-7 set-focus,
D-8 grabs, D-9 subsurfaces) are general privileged-client capabilities
in semadraw, not NDE-specific access paths; the repository boundary is
not blurred. The conformant Surface Manager design and implementation
live in the NDE repository, not in UTF.

### `[ ]` NDE-2: System Bar  *(Open, Small-Medium)*

**Depends on**: NDE-1
**Tracks**: NDE Milestone 2, daily driver core

A persistent surface at a fixed screen edge showing: active
application name, workspace indicator, clock, and system status.
Rendered entirely in SDCS via libsemadraw.

### `[ ]` NDE-3: Launcher  *(Open, Medium)*

**Depends on**: NDE-1
**Tracks**: NDE Milestone 2, daily driver core

Application discovery and launch. Reads a manifest of installed NDE
applications, presents a keyboard-navigable launcher surface, and
spawns selected applications as managed semadraw clients.

### `[ ]` NDE-5: X11 Compatibility Bridge  *(Open, Large)*

**Depends on**: NDE-1, SM-1
**Tracks**: NDE Milestone 3, compatibility

Rootless X11 server integration: map X windows to semadraw surfaces,
translate input and clipboard, integrate drag and drop. IME integration
path required for international use.

**Classification note**: the NDE DESIGN.md originally described the
X11 bridge as "mandatory for usability." This has been revised to
**required for compatibility**. UTF now has a native terminal
(`semadraw-term`), and NDE is semantic-native (ratified 2026-06-12;
LT-3 retired). The X11 bridge remains important for running existing
legacy X11 applications but is no longer a prerequisite for the
environment to be usable. With LT-3 retired, NDE-5 is the sole
compatibility tenant; any further tenant requires its own ADR and
stays fenced from the native semantic vocabulary.

## SM: Session Management

SM is the PGSD distribution layer's session-management track,
covering authentication, login, session lifecycle, and related
concerns. It is desktop-agnostic by design: SM components do not
depend on NDE, do not encode NDE-specific behaviour, and could in
principle be reused by a different distribution built on UTF.

The track was opened on 2026-05-10 to replace the original NDE-4
"Session Manager" entry, which conflated session management with
desktop work. See `docs/sessions/2026-05-10.md` for the
architectural reasoning and `pgsd-sessiond/docs/adr/0001-design.md`
for the SM-1 design.

The `pgsd-` prefix marks distribution-layer components, distinct
from UTF userland's `sema-` prefix. UTF has stable substrate
contracts; PGSD is one set of choices on top of those contracts.

### `[ ]` SM-2: screen lock daemon  *(Open, Small-Medium)*

**Depends on**: SM-1.

A screen-lock daemon that reuses SM-1's PAM stack to require
re-authentication after idle timeout or explicit user request,
without tearing down the user's session. Out of v1 SM-1 scope;
opens as a separate item when SM-1 is far enough along to expose
the right hooks.

Design pending. Likely a small daemon launched per-session by
the user's session leader, sitting alongside whatever desktop
environment is running. Unlocks the screen via the same PAM
conversation SM-1 uses for login, but does not exec a new
session leader; it just dismisses the lock surface.

ADR drafted 2026-06-09: `pgsd-sessiond/docs/adr/0010-screen-lock-daemon.md`
(Accepted 2026-06-09). A per-session daemon that never tears down the session.
Re-auth is performed entirely by pgsd-sessiond (the alive root parent,
outside the session's trust boundary, that did the login and owns the
PAM stack): on a secret-free lock trigger it becomes the compositor's
lock client, draws the prompt, collects the password directly into
`mlock`ed memory, runs PAM, and zeroes it. The cleartext never enters
a user-level process or a socket (D2, revised 2026-06-09; supersedes
the initial password-forwarding draft). A secure lock requires a new
compositor-enforced session-lock mode in semadraw (only the lock
surface presents, all input routes to it, overriding WM policy), with
pgsd-sessiond as the lock client; z-order, set-focus (D-7), and grab
(D-8) are best-effort, not a boundary (D3). v1 is secure-only, no best-effort interim lock (D4, ratified). Idle detection publishes semadrawd's existing
`last_input_ts_ns` (D5), the plumbing SM-3 (ADR 0009) consumes; the
per-session policy agent owns the timeline and triggers, pgsd-sessiond
owns the privileged and secret-bearing actions. Gated on two semadraw
additions (D-10 secure-lock mode; D-11 `last_input_ts_ns` publication)
and the pgsd-sessiond lock interaction; not implementable until those
land.

### `[ ]` SM-3: idle and power management integration  *(Open, Medium)*

**Depends on**: SM-2 (for the idle-detection plumbing).

Idle-state tracking and power-management integration: blanking
the display after configurable idle, suspending the system on
deeper idle, handling the resume-from-suspend case (which may or
may not require re-authentication depending on the operator's
policy via SM-2). Out of scope for v1 SM-1.

This is the natural home for "agent-of-record for
`XDG_RUNTIME_DIR`-equivalent" if PGSD chooses to ship one. The
ADR for SM-3 will decide whether to adopt the FreeDesktop
convention, define a PGSD-native equivalent, or punt entirely.

ADR drafted 2026-06-09: `pgsd-sessiond/docs/adr/0009-idle-and-power-management.md`
(Accepted 2026-06-09). A staged idle timeline (T1 blank and lock, T2 suspend),
both thresholds configurable and independently disablable. Idle
detection is consumed from SM-2 through a defined contract (a per-
session monotonic idle measure), not read from inputfs directly.
Blanking is two-tier: compositor-black now (content-hiding, pairs with
the lock, no power saving), true display power-down later as a drawfs
contract (AD-4 / DF-6); the deep-idle energy win is suspend, which
reuses pgsd-sessiond's existing `acpiconf -s 3` path. Resume and
re-auth defer to SM-2. The idle/power policy lives in SM-2's
per-session daemon (D6, flagged for ratification), not a new daemon or
pgsd-sessiond. The `XDG_RUNTIME_DIR`-equivalent question is resolved by
reference to ADR 0005 (which already ships `/var/run/pgsd/<uid>/` under
both `PGSD_RUNTIME_DIR` and `XDG_RUNTIME_DIR`), leaving only an optional
multi-session refcount. Not implementable until SM-2 lands.

### `[x]` SM-5: quick-exit guard false-positive on clean logout  *(Closed 2026-06-13, operator-ratified; fix verified in source. Opened 2026-06-09, Small, P2)*

Follow-up defect in the SM-4 login-UI area. After a clean login then
logout, the next login screen shows "session exited quickly (code 0);
check configuration" whenever the session ran under the 2s quick-exit
threshold (the guard in `main.zig`). The heuristic keys only on
duration, so a deliberate short session (log in, log straight back out)
is misread as a failed or misconfigured start. It cannot be a real
start failure: `launch()` maps fork/exec/setusercontext/setsid failures
to nonzero codes (`EXIT_LAUNCH_FAILED` 8, `EXIT_INTERNAL` 20), while a
clean logout returns the leader's exit status (0). Fix: gate the warning
on a nonzero exit (`child_exit != 0 and launch_elapsed_ns <
QUICK_EXIT_THRESHOLD_NS`), so a clean exit is silent at any duration
while a genuinely failed or fast-erroring start (nonzero) is still
flagged. No ADR (AD-fix under this entry). Observed on pgsd-bare-metal
2026-06-09.

**Closed 2026-06-13.** Verified in `pgsd-sessiond/src/main.zig`: the
session-loop quick-exit guard gates on `child_exit != 0 and
launch_elapsed_ns < QUICK_EXIT_THRESHOLD_NS`, so a clean code-0 logout
is silent at any duration while a fast nonzero exit is still flagged.
The exit-code gate is documented in the inline comment at the guard
(it names SM-5) and in the daemon header comment. The landed code
matches the Fix paragraph above; no further work.

## Architectural Discipline

The project's discipline (UTF depends only on code written with UTF's
guarantees in mind) is stated in full at
`docs/AWASE_ARCHITECTURAL_DISCIPLINE.md`. This section tracks the work
streams that apply the discipline to subsystems where external
dependencies currently sit inside UTF's guarantee path. Items here
represent multi-stage replacements, not individual features; each
item typically has its own design document or proposal that details
the stages.

### `[~]` AD-1: inputfs: native input substrate  *(In progress, Large)*

**Tracks**: `inputfs/docs/inputfs-proposal.md` and
`inputfs/docs/foundations.md`.

Replace the evdev / bsdinput / libinput dependency chain with
`inputfs`, a UTF-owned kernel input substrate. Publishes input state
and events via shared memory, timestamps with the UTF dual-clock
(monotonic + audio-sync), routes events via compositor-driven focus.
Closes the coordinate-space bug (previously tracked as D-6 and
superseded by this item), eliminates device-accumulated coordinates,
and removes userspace semainputd as a component (see AD-2).

**Status**: Stages A, B, C, and D complete (all eight Stage D
sub-stages landed: D.0a, D.0b, D.1, D.2, D.3, D.4, D.5, D.6).
The chronofs `ts_sync` integration deferred from Stage C
landed 2026-05-05 and is **partially verified** on bare metal:
every event now stamps `ts_sync` from a kthread-refreshed
cache of `/var/run/sema/clock` at emit time. The
clock-absent / `clock_valid = 0` failure path is verified
end-to-end (clock file shows byte 5 = 0, events show
`ts_sync = 0`, no log spam, fall-through is correct). The
non-zero stamping path requires an active semaaud client
driving a real audio stream (no such client exists in the
tree today; OSS shim writes to `/dev/dsp` bypass semaaud);
final verification of non-zero `ts_sync` is therefore
deferred until a semaaud client is available, likely as a
side effect of AD-3 audio-output work or earlier
audio-app integration. The success path is structurally
trivial given the failure path works (a `memcpy` of 8 bytes
plus an atomic load, no intermediate logic), but trivial
isn't verified, so the partial-verification status is
accurate. The HUP_DIGITIZERS parser sub-item, formerly
listed here as deferred, **landed and was verified on bare
metal 2026-05-06** (commits 9bb35ff steps 2+3, fb018da
steps 4+5, closure 183410a; classifier role, field
locator, report-byte parser, and Touchpad Mode
feature-report send all implemented, wired in at
inputfs.c, and verified end-to-end against the HAILUCK
0x258a:0x000c trackpad). See the "Sub-item: HUP_DIGITIZERS
parser for Win8+ multi-touch" section below, which carries
the full Done status and verification evidence; this
summary previously contradicted it and is corrected here.
Two AD-1 sub-items now remain post-Stage-D and keep this
entry at `[~]` rather than `[x]`: pollable-fd /
kqfilter for the events ring (small-medium; semadrawd's
existing poll-and-drain loop absorbs events fine in
practice; the pollable fd is a latency improvement, not a
correctness gate; verified absent from inputfs.c as of
this audit); and a separate parallel sub-item for Apple
multi-touch trackpad support (medium-large; vendor-specific
protocol distinct from Microsoft Win8+ HUP_DIGITIZERS,
requires reverse-engineered prior-art reference; verified
absent from the inputfs sources as of this audit; not
gating Phase 2.5 multi-touch verification, which targeted
the HAILUCK HUP_DIGITIZERS path and is now closed). Both
remaining items appear in their longer form near the end
of this entry. Stage E
(semainputd retirement, AD-2) was completed: AD-2 closed
2026-05-17 (see AD-2 entry in BACKLOG-history.md); AD-9
hardening was completed before that cutover.

Stage A delivered the proposal, foundations,
`AWASE_ARCHITECTURAL_DISCIPLINE.md`, ADRs 0001 through 0011, and
four byte-level companion specs (`shared/INPUT_STATE.md`,
`shared/INPUT_EVENTS.md`, `shared/INPUT_FOCUS.md`, and
`shared/INPUT_IOCTL.md`). Stage B delivered HID attachment via
hidbus, descriptor parsing, interrupt handler registration, raw
report hex logging, and per-device role classification. Stage C
delivered userspace publication of the state region and event
ring. Stage B and Stage C sub-stage detail follows.

Stage B sub-stages:

- **B.1** module skeleton loads and unloads cleanly: landed,
  verified.
- **B.2** device attachment on `hidbus` with HID TLC matching
  per ADR 0007: landed, verified on Razer Viper (live system)
  and VirtualBox USB Tablet (VM).
- **B.3** HID report descriptor fetch and walk per ADR 0008:
  landed, verified on VirtualBox USB Tablet (85-byte descriptor,
  11 input items, depth 2).
- **B.4** interrupt handler registration via `hidbus_set_intr`
  and raw report hex logging per ADR 0009: landed, verified on a
  physical USB mouse passed through to a FreeBSD VirtualBox VM.
  Live reports flow with non-zero motion deltas during use;
  `inputfs0: detached` on unplug; clean `kldunload` with no dmesg
  warnings.
- **B.5** per-device role classification into softc bitmask
  per ADR 0004 and ADR 0010: landed, verified on the PGSD kernel
  on bare metal. Six USB HID devices across three TLC classes
  attached and classified correctly: ELECOM BlueLED Mouse
  (vendor=0x056e, product=0x00e3, roles=pointer); HAILUCK
  touchpad keyboard TLC (vendor=0x258a, product=0x000c,
  roles=keyboard); HAILUCK touchpad mouse TLC (same vendor:product,
  roles=pointer); Broadcom Bluetooth keyboard TLC
  (vendor=0x05ac, product=0x8294, roles=keyboard); Broadcom
  Bluetooth mouse TLC (same vendor:product, roles=pointer);
  Apple Keyboard (vendor=0x05ac, product=0x021d, roles=keyboard).
  Report flow verified at 640 lines for sustained mouse input.
  Clean `kldunload` produced six `detached` lines and no dmesg
  warnings.

ADR 0006 was drafted against legacy `ukbd`/`ums` reference
drivers that are not loaded on modern FreeBSD 15; it is superseded
by ADR 0007 (hidbus attachment). The shipped code attaches at
`hidbus` and works against the modern HID stack. ADR 0008 carries
an errata section recording a `hid_start_parse` kindset correction
made during B.3 verification.

**Verification environment note (B.5).** Bare-metal verification
on stock FreeBSD is structurally blocked: stock FreeBSD compiles
`hkbd` statically into the GENERIC kernel and ships `hms`, `hkbd`,
`hcons`, `hsctrl`, and other competing HID drivers as auto-loadable
modules with `linker.hints` registrations. The ADR 0009 workflow
of unloading competing drivers cannot succeed against statically
compiled code, and even when modules are unloaded at runtime the
kernel auto-load machinery reloads them on the next USB event.
The PGSD kernel resolves this: `nodevice` lines remove the
competing drivers from the static kernel image (see
`pgsd-kernel/PGSD`), and the build-produced `.ko` files in
`/boot/kernel/` are moved aside before verification so
`linker.hints` cannot find them to autoload (a stopgap; the durable
answer is `WITHOUT_MODULES` in `/etc/src.conf`, tracked under
AD-8). With both kernel image and module files clean of
competitors, `inputfs` binds at `hidbus` without contention and
all four B.5 signals pass. Earlier VirtualBox-based verification
in this project's history exercised the mouse path on a Razer
Viper but is no longer the reference: PGSD targets bare-metal
FreeBSD, and B.5's verifying evidence is the bare-metal PGSD-kernel
run captured in `b5-pass2-baremetal.log`. The verification
protocol in `inputfs/docs/B5_VERIFICATION.md` documents the
workflow.

**Stage C: state publication.** Per the inputfs proposal, Stage C
made inputfs's internal state visible to userspace through three
shared-memory regions under `/var/run/sema/input/`. The regions
are specified in `inputfs/docs/adr/0002-shared-memory-regions.md`
with byte-level layouts in `shared/INPUT_STATE.md`,
`shared/INPUT_EVENTS.md`, and `shared/INPUT_FOCUS.md` (all
landed as Stage A artifacts). Stage C implemented against those
specs. semainputd remained unchanged; evdev still drove
production; inputfs gained a user-visible output but no
consumers yet.

Stage C broke into five sub-stages, mirroring Stage B's rhythm:
each sub-stage landed and was verified independently before the
next started. Sub-stage detail follows.

- **C.1** `shared/src/input.zig` library: `StateWriter`/`StateReader`,
  `EventRingWriter`/`EventRingReader`, `FocusWriter`/`FocusReader`.
  Mirrors the `clock.zig` pattern. Pure Zig, userspace-testable
  with unit tests. No kernel work, no hardware dependency. Lands
  the API surface that the kernel writer (C.2, C.3) and the CLI
  reader (C.4) both build against. Landed 2026-04-27 with 15
  passing unit tests covering size constants, parent dir creation,
  magic rejection, pointer and device round-trips, ring drain
  ordering, ring overrun, and focus pointer resolution.
- **C.2** kernel state-region writer in `inputfs.c`: creates
  `/var/run/sema/input/state` on module load per the byte layout
  in `shared/INPUT_STATE.md` and the regions decision in
  `inputfs/docs/adr/0002-shared-memory-regions.md`. Publishes
  device inventory from B.5's softc role bitmask, updates the
  seqlock-protected fields on every event admission. Pointer
  position is published in raw device space; coordinate transform
  to compositor space is Stage D work (per ADR 0002 §Decision item 5,
  the transform mechanism is deferred). Landed 2026-04-27 with
  end-to-end verification on PGSD-bare-metal: six HID devices
  (ELECOM mouse, HAILUCK touchpad keyboard and pointer, Broadcom
  Bluetooth keyboard and pointer, Apple Keyboard) reporting correct
  vendor, product, roles, and names. Architecture: 11,328-byte
  module-global live buffer, MTX_SPIN serialization, kthread
  worker syncing via vn_rdwr.
- **C.3** kernel event-ring writer in `inputfs.c`: creates
  `/var/run/sema/input/events`, appends events to the ring on
  every interrupt callback (the path that currently logs hex to
  dmesg in B.4). Sequence numbers strictly monotonic. `ts_ordering`
  comes from the kernel monotonic clock; `ts_sync` either wired
  to chronofs (preferred, gives ADR 0011 measurement substrate)
  or left zero (the spec allows it). Pollable fd via `kqueue`.
  Landed 2026-04-27 with verification on PGSD-bare-metal: 224
  pointer.motion events plus left and right button cycles, all
  with strictly monotonic seqs and timestamps. Per-event
  publication uses partial vn_rdwr writes (slot plus header,
  ~128 bytes per typical sync). The pollable fd is deferred to
  a follow-on sub-stage. ts_sync left zero; chronofs integration
  also deferred. Keyboard, touch, and pen events deferred (need
  descriptor-driven parsing).
- **C.4** `inputdump` CLI tool in Zig under `inputfs/tools/`,
  parallel to `chronofs/tools/chrono_dump.zig`. Reads the state
  region and event ring, presents them. Useful for verification
  end-to-end and for ad-hoc debugging. Landed 2026-04-27 with
  four subcommands (`state`, `events`, `watch`, `devices`),
  human-readable and `--json` output, and event filtering by
  role, device slot, and event type. The C.2/C.3 throwaway
  `inputstate-check.zig` was deleted in the same commit.
- **C.5** verification protocol (`inputfs/docs/C_VERIFICATION.md`)
  plus scripts under `inputfs/test/c/`: signals for region
  creation, header validity, device inventory publication, event
  ring monotonicity, pollable-fd wakeups, clean unload. Pattern
  follows B.5's verification protocol. Landed 2026-04-27 with
  `c-verify.sh` (top-level orchestrator running seven phases
  end-to-end) and `c-fixtures.sh` (sourced helper library).
  Pollable-fd verification deferred along with the pollable fd
  itself; the protocol document notes the placeholder.

The Stage A focus region (`shared/INPUT_FOCUS.md`) is part of C.1's
library deliverable: `FocusWriter`/`FocusReader` belong in
`shared/src/input.zig` because the API surface is shared. The
kernel-side *use* of `FocusReader` (consuming compositor focus to
route events) is Stage D work, not Stage C.

The state region's spec describes `pointer_x`/`pointer_y` as
compositor-space. Stage C publishes them in raw device space
because inputfs has no transform machinery yet; that machinery
arrives in Stage D. The state region remains structurally correct
across the transition; only the semantics of what's in those
two fields changes.

**C.2 kernel-side considerations** *(historical, pre-implementation
design notes; the choices below were made and the implementation
landed accordingly)*. The state region is 11,328
bytes on disk, single-writer (the kernel), multiple-reader
(userspace). Userspace consumers mmap the file shared and read
via `StateReader` from `shared/src/input.zig`; the kernel
cannot link userspace Zig and instead writes the same byte
layout from kernel context. Several FreeBSD-specific decisions
shape the implementation:

- **File creation and write path.** The kernel cannot mmap a
  userland filesystem path the way userspace does. The two viable
  patterns are (a) `vn_open` plus `vn_rdwr` from a kthread
  context, opening `/var/run/sema/input/state` as a regular file
  and overwriting it byte-for-byte on every state update, or
  (b) maintaining the canonical state in a kernel-resident buffer
  and bouncing updates to userland via a helper. Neither pattern
  has precedent in the UTF codebase: existing userland files
  under `/var/run/sema/` (the audio clock, the session token)
  are written by userspace daemons. inputfs C.2 is the first
  kernel-context writer of a `/var/run/sema/` file. Pattern (a)
  is the simpler path. C.2 will start with (a) and measure;
  pattern (b) becomes a tractable optimisation if (a)'s overhead
  is intolerable.
- **Mutex strategy.** B.5's `sc_mtx` per softc protects per-device
  state during attach, classification, and the interrupt path.
  The state region adds a global resource: the seqlock counter,
  the device inventory array, and the per-event `last_sequence`
  value all need atomic-multi-field-update semantics. A new
  module-global mutex (provisionally `inputfs_state_mtx`) will
  bracket seqlock increments and field writes; the per-softc
  `sc_mtx` remains for per-device state. Order is
  `sc_mtx` then `inputfs_state_mtx` to avoid deadlock on attach.
- **Writer context.** State updates land from interrupt callback
  context (B.4's `inputfs_intr` path). Vnode I/O from interrupt
  context is forbidden in FreeBSD; that means the writer cannot
  call `vn_rdwr` directly from `inputfs_intr`. The interrupt
  handler must enqueue the state update onto a kthread-backed
  worker that performs the vnode write outside interrupt context.
  This is a non-trivial dispatch boundary and is the chief
  reason C.2 is sized larger than C.1.
- **Unload semantics.** On `kldunload`, the state region file
  is left in place (per the spec's "file persists; next load
  resets it" lifecycle note). The kthread worker must drain
  pending writes before the module unloads to avoid use-after-free
  on the softc state.
- **Module-load message.** `inputfs_modevent`'s current
  `MOD_LOAD` `printf` advertises Stage B.5. C.2's commit
  updates that string to reflect state-region publication and
  drops the "no userspace event delivery" qualifier (which
  becomes false at C.3, not C.2; C.2 publishes state but not
  yet the event ring).

**C.5 verification signals (preview)** *(historical, pre-implementation
design notes; the verification protocol that landed in C.5 covers
all of these signals plus several more)*. When C.2 lands the
verification protocol in `inputfs/docs/C_VERIFICATION.md` should
exercise, in the pattern established by `b5-verify-reports.sh`:

- State file presence and permissions: `/var/run/sema/input/state`
  exists after `kldload inputfs`, is `STATE_SIZE` bytes (11,328),
  is readable by the user account that runs userspace tools.
- Header validity: magic decodes to `INST` (`0x494E5354`),
  version is 1, `state_valid` transitions 0 to 1 once the first
  device attaches.
- Device inventory: the populated slots in the device array
  match the attached devices observed in `dmesg` after `B.5`'s
  `roles=` lines, with `roles` bitmasks consistent with B.5's
  classification.
- Seqlock toggling: under sustained input, `seqlock` advances
  by even pairs (writer increments twice per update); a
  userspace `inputdump` (C.4) capturing N snapshots over a
  recorded interval observes monotonic advance.
- Clean unload: `kldunload inputfs` completes without panics,
  the kthread worker drains, the state file persists with
  `state_valid = 1` until the next load truncates it.

These signals are concrete enough to write the verification
script against once C.2 and C.4 are both landed.

**Stage C closeout (2026-04-27).** All five sub-stages landed
and were verified end-to-end on PGSD-bare-metal with six HID
devices: the ELECOM BlueLED Mouse, HAILUCK touchpad keyboard
and pointer TLCs, Broadcom Bluetooth keyboard and pointer TLCs,
and Apple Keyboard. State region and event ring publish
correctly, magic and version match the spec, device inventory
matches dmesg, lifecycle events fire one per attaching device
with monotonic seqs, pointer.motion events stream from the
ELECOM mouse, button transitions emit pointer.button_down and
pointer.button_up correctly. Module load, unload, and reload
cycles are clean with no `M_INPUTFS` leaks. The verification
protocol at `inputfs/docs/C_VERIFICATION.md` captures the full
test recipe; `inputfs/test/c/c-verify.sh` reports 26 of 26
automated checks passing.

**Stage C deferred items.** Three items were scoped out of Stage
C; their disposition is now:

- *Pollable fd.* Still deferred. The `/dev/inputfs` cdev with
  `kqfilter` and `EVFILT_READ` support, so userspace consumers
  can block on events instead of polling the ring. Stage C's
  userspace consumers poll at an interval (the inputdump
  default is 100 ms); this is fine for a diagnostic tool and
  semadrawd's main poll loop absorbs events without measurable
  drop in practice. The pollable fd is a latency improvement
  rather than a correctness gate; can wait until AD-2 surfaces
  a need.
- *chronofs `ts_sync` integration.* **Landed 2026-05-05** as
  part of AD-1's tail; **partially verified** on bare metal.
  Every event now stamps `ts_sync` from a kthread-refreshed
  cache of `/var/run/sema/clock` at emit time. Cache refresh
  follows the D.1 focus-reader pattern (vn_rdwr from kthread,
  spin-locked snapshot for interrupt consumers); the kernel
  does not mmap the clock file. When the clock file is absent
  (semaaud not running), magic or version mismatch, or
  `clock_valid = 0`, `ts_sync` falls through to the documented
  `0` sentinel; no regression for consumers that already
  handle the unavailable case. The failure path is verified
  end-to-end: clock byte 5 = 0 → events emit with
  `ts_sync = 0` → no log spam → fall-through is correct.
  The non-zero stamping path (`clock_valid = 1` and
  `samples_written` advancing) is *not* verified because no
  semaaud client exists in the tree today; OSS shim writes to
  `/dev/dsp` bypass semaaud's userland accept loop. Final
  verification of non-zero `ts_sync` is deferred until a
  semaaud client exists, likely as a side effect of AD-3
  audio-output work or earlier audio-app integration. The
  success path is structurally trivial given the failure path
  works (a `memcpy` of 8 bytes plus an atomic load, no
  intermediate logic), but the verification is honest about
  what was tested and what wasn't.
- *Descriptor-driven event generation for keyboard, touch, pen,
  and scroll.* Keyboard, scroll, and basic descriptor-driven
  pointer parsing landed under Stage D (D.0a + D.0b). Touch
  and pen remain deferred per ADR 0012; they need digitizer
  hardware to verify and are tracked in this entry's tail
  alongside the pollable-fd item.

**Stage D: focus routing and coordinate transform.** Stage C
publishes input data in raw device space; Stage D adds the
transform machinery that maps device coordinates to compositor
space, and consumes the focus region to route events to the
correct session. Stage D is scoped in
`inputfs/docs/adr/0012-stage-d-scope.md`, which records the
design decisions made during Stage D scoping (sysctl-based
geometry exposure from drawfs, kernel-side focus routing in
inputfs, stamp-and-filter session_id placement, transform_active
byte for coordinate semantics signaling, `hw.inputfs.enable`
tunable semantics, and descriptor-driven event scope).

Stage D breaks into eight sub-stages, each landed and verified
independently before the next starts. The dependency order is
approximately D.0a or D.0b first (independent of each other),
then D.1 and D.2 (independent of each other), then D.3 and D.4
(D.3 depends on D.2 and D.0a; D.4 depends on D.1), then D.5,
then D.6.

- **D.0a** descriptor-driven pointer events: replace
  boot-protocol parsing with `hid_locate`-based extraction at
  attach + `hid_get_data` calls at interrupt time. Adds
  report-ID dispatch for devices with multiple top-level
  collections. Adds scroll-wheel event type if `HUG_WHEEL` is
  present. *Landed (commits `123a2b4` and `309329d`).*
- **D.0b** descriptor-driven keyboard events: emit
  `keyboard.key_down` / `keyboard.key_up` from descriptor-driven
  parsing of the modifier byte and the keys-held array under
  HUP_KEYBOARD. Tracks held keys in the softc to compute
  transitions. Modifiers carried in each event's payload field
  (per existing `shared/INPUT_EVENTS.md` spec); no separate
  modifier-transition events. *Landed (commit `42dfd57`).*
- **D.1** kernel-side `FocusReader` equivalent in C: mmap the
  focus file at module load (or first use), retry until
  `focus_valid = 1`, snapshot under the seqlock retry protocol,
  surface `keyboard_focus`, `pointer_grab`, and `surface_map`
  for routing. *Landed (commits `35ab475` and `948d346`).
  Implementation uses `vn_rdwr` against a cached buffer rather
  than mmap; the kthread refreshes via bounded `msleep_spin`
  every ~100 ms, and `inputfs_focus_snapshot` is safe to call
  from interrupt context under spin lock. Seqlock retry is
  folded into the refresh-then-validate cycle.*
- **D.2** drawfs geometry sysctl: drawfs publishes display
  geometry under `hw.drawfs.efifb.*`; inputfs reads at module
  load via `kernel_sysctlbyname`, falls back to a conservative
  default if the sysctls are absent. *Landed (commits `f7cb38f`,
  `8804e60`, and `732f737`).*
- **D.3** coordinate transform: clamp pointer position to
  display bounds learned from D.2, publish in compositor
  pixel space, set `transform_active = 1` in the state region
  header. Seed pointer to display centre on first activation.
  *Landed (commit `e644594`).*
- **D.4** routing application: stamp events with
  `session_id` from the focus snapshot, synthesise
  `pointer.enter` and `pointer.leave` events when
  surface-under-cursor changes between successive pointer
  events. Apply keyboard-focus routing (events delivered to
  `keyboard_focus` if non-zero). *Landed (commit `0c610fd`).*
- **D.5** `hw.inputfs.enable` tunable: gate publication.
  When `0`, inputfs is fully inert (no state updates, no
  ring updates, `state_valid = 0`, `events_valid = 0`).
  When `1`, full publication. Clean valid-byte transitions
  on flip. *Landed (commit `d0dd1fc`).*
- **D.6** Stage D verification protocol: extend
  `c-verify.sh` (or write a new `d-verify.sh`) and a
  `D_VERIFICATION.md` document. Mirrors C.5's automated
  phases plus a manual checklist for keyboard events
  (D.0b), transform behaviour (D.3), routing (D.4), and
  the tunable's transitions (D.5). *Landed (commit
  `f5e2ada`); chose new `d-verify.sh` rather than
  extending `c-verify.sh`.*

Touch and pen events are explicitly out of scope for Stage D
(per ADR 0012); they are tracked as a separate AD-1 sub-item
post Stage D. The chronofs `ts_sync` integration (Stage C
deferred item) also stays separate from Stage D unless D.6
verification surfaces a need for it.

**Closed finding (2026-05-06): D.3 emits motion events with
non-zero dy while y stays at 0** *(was Small)*. Originally
surfaced during AD-2a Phase 1 verification via `inputdump
events`. When the pointer was held at a screen edge, motion
events reported `y = 0` and `dy = -N` for many frames in a
row even though the position didn't change, producing phantom
drift in consumers that integrate `(dx, dy)` to maintain their
own pointer state.

The fix landed in `inputfs_state_update_pointer`: the function
now returns the post-clamp delta (the actual change in position
after edge clamping) via two out-parameters, and the motion
event emitter writes those into the payload's `dx`/`dy` fields
instead of the raw HID deltas. When clamping is inactive
(geometry unknown), the post-clamp deltas equal the raw deltas,
so behaviour without drawfs is unchanged. When the cursor is
held against an edge, payload `dx`/`dy` now report 0 in that
direction instead of the unrealised raw delta.

ADR 0012 D.3 description amended to reflect the new behaviour.
D_VERIFICATION.md D.3 manual checklist updated with a
post-clamp-delta verification step. Compositor consumers
that read absolute (x, y), including the current production
`semadrawd` are unaffected; the bug only manifested for
consumers that integrated `(dx, dy)`. Effect on AD-2a Phase 1
verification capture: the original `dy = -N while y = 0`
sequence at the top wall now reports `dy = 0`.

#### Sub-item: HUP_DIGITIZERS parser for Win8+ multi-touch *(Medium-Large)*

**Status:** **Done 2026-05-06.** Scoped 2026-05-05; hardware
identified, characterized, descriptor decoded, ADR written
(ADR 0018 plus 2026-05-05 amendment correcting Touchpad Mode
mechanism); classifier extension, locator, parser, and Touchpad
Mode feature-report send all implemented and verified end-to-end
on bare metal against the HAILUCK 0x258a:0x000c trackpad.

**Verification evidence:** session 2026-05-06 on
`pgsd-bare-metal-test-machine`. dmesg attach line for the HAILUCK
trackpad (inputfs2) shows the full chain: pointer locations
cached, digitizer locations cached (report_id=7, all eight fields
present, x_range=[0..1535] y_range=[0..1023]), roles=pointer,touch,
and "Device Mode set to MT Touchpad (report_id=11 rlen=2)".
inputdump events captured the touch lifecycle for several
gestures including single-finger drag (one type1, ~110 type2s,
one type3), two-finger drag (interleaved per-contact-id type1/
type3 events), and brief taps. Per-contact tracking works,
per-Q1 per-report emission works, per-Q2 confidence-low handling
didn't trip on any input. The Phase 2.5 verification status doc
section 7 deferral entry closes on the strength of this
evidence.

**Why this exists:** scenarios 7-9 of
`semadraw/docs/PHASE_2_5_VERIFICATION.md` (pinch,
two-finger scroll, three-finger swipe) require
`SOURCE_TOUCH` events with contact tracking. inputfs's
existing pointer-locate path (Stage D.0a) walks past
HUP_DIGITIZERS collections because no parser for that
usage page exists yet. The deferred multi-touch
verification BACKLOG entry under AD-2a points here as
its blocker.

**Hardware target:** HAILUCK USB touchpad
(vendor=0x258a, product=0x000c) on
`pgsd-bare-metal-test-machine`. The device's 505-byte
HID report descriptor was captured 2026-05-05 via the
`hw.inputfs.debug_descriptor` sysctl introduced in
commit `41e8f74`. Decoded byte-by-byte, the descriptor
contains:

  - **Report ID 1:** legacy 5-button mouse fallback
    (HUP_GENERIC_DESKTOP, what inputfs currently
    parses).
  - **Report ID 7:** full multi-touch digitizer
    (HUP_DIGITIZERS, usage 0x05 Touch Pad), with a
    Finger collection (usage 0x22) containing Tip
    Switch (0x42), Confidence (0x47), Contact
    Identifier (0x51, 3-bit, supports up to 8
    contacts), X (15-bit, physical max 800 in cm
    units), Y (15-bit, physical max 600), Scan Time
    (0x56), Contact Count (0x54), and Button 1 from
    HUP_BUTTON for the clickpad button.
  - **Report IDs 2, 3, 9:** system / consumer /
    wireless control buttons (top-row keys, brightness,
    volume, WLAN radio).
  - **Report IDs 5, 6, 10:** vendor-defined feature
    reports (firmware configuration, opaque to the
    parser).
  - **Report IDs 8, 11, 12, 13:** Win8+ touchpad
    capability and configuration feature reports
    (Contact Count Maximum 0x55, Pad Type 0x59, Device
    Configuration, Surface Switch + Button Switch,
    Latency Mode 0x60).

This is the same descriptor shape Linux's
`hid-multitouch` and FreeBSD's `wmt(4)` driver target.

**Critical subtlety: device starts in Mouse Mode.**
Win8+ touchpads emit either Report ID 1 (mouse mode)
or Report ID 7 (touchpad mode) depending on the
Surface Switch + Button Switch bits in Report ID 12
feature output. By default the device is in Mouse Mode
and emits only Report ID 1. inputfs must send a
feature report at attach time with both bits set to
switch the device into Touchpad Mode. Without this,
even with the parser implemented, the device will
continue to emit only mouse-class reports.

**Implementation plan (roughly one week of kernel
work plus testing iterations):**

  1. **Walk the rest of the descriptor.** *Done
     2026-05-05.* Full descriptor walk captured in
     `inputfs/docs/adr/0018-hup-digitizers-parser.md`
     section 1 (verified descriptor structure for
     HAILUCK 0x258a:0x000c). Two findings shape
     subsequent steps: (a) the descriptor declares
     **one Finger collection per Report ID 7**, so the
     parser emits one event per arrival
     ("hybrid mode" pattern from the Microsoft
     Precision Touchpad spec); (b) the device starts
     in Mouse Mode by default and emits Report ID 7
     only after the host writes Device Mode = 0x03
     (Multi-touch Touchpad) to the Device Mode feature
     field, which on the HAILUCK lives in Report ID 11.
     Both findings are documented in ADR 0018 sections
     2 and 3, with the ADR amendment of 2026-05-05
     correcting an earlier misidentification of the
     mode-switch mechanism. Report ID 7 layout (bit
     offsets and field sizes) is in section 1; Report
     ID 11 layout and Device Mode value table is in
     section 3.

  2. **Add HUP_DIGITIZERS classifier role.** *Done
     2026-05-06* (commit 9bb35ff). Extended the
     Stage B.5 role bitmask with a second pass over
     the descriptor's Application Collections looking
     for HUP_DIGITIZERS Touch Pad / Touch Screen / Pen
     usages. Devices presenting a Touch Pad collection
     gain INPUTFS_ROLE_TOUCH; devices presenting a Pen
     collection gain INPUTFS_ROLE_PEN. The matched-TLC
     first pass remains unchanged so devices presenting
     only one Application Collection classify identically
     to before. The HAILUCK trackpad now classifies as
     `roles=pointer,touch` instead of just `roles=pointer`.

  3. **Add `inputfs_digitizer_locate` analog of
     `inputfs_pointer_locate`.** *Done 2026-05-06*
     (commit 9bb35ff). The locator pins down the
     digitizer's report ID by locating Tip Switch
     first (HUP_DIGITIZERS-specific, only appears in
     the digitizer collection), then iterates
     `index = 0, 1, 2, ...` for Generic Desktop X /
     Y / Button 1 to skip past the Mouse-fallback
     occurrences and find the digitizer's. All eight
     fields plus X/Y logical ranges populate the
     parser_state cache. Verified bare-metal: every
     bit offset and logical range matches the
     descriptor decode in ADR 0018 section 1.

  4. **Implement the per-Report-ID-7 parser** that
     emits `touch.touch_down` / `touch.touch_move` /
     `touch.touch_up` events per
     `shared/INPUT_EVENTS.md`. *Done 2026-05-06*
     (commit fb018da). Mapping landed:

       - Tip switch rising edge for a contact ID →
         `touch.touch_down` with that contact ID.
       - Subsequent reports with same contact ID and
         tip switch high → `touch.touch_move`.
       - Tip switch falling edge → `touch.touch_up`.
       - Confidence low → treated as tip_switch=0
         (synthesises touch_up if mid-contact,
         suppresses touch_down on new low-confidence
         contact). Recorded as Q2 design choice.
       - Scan time extracted but not surfaced;
         ts_ordering uses kernel monotonic, matching
         the pointer/keyboard paths.
       - Button 1 → emitted via INPUTFS_SOURCE_POINTER
         with the same payload layout the Mouse-fallback
         Report-ID-1 path uses, so consumers see one
         button_down/up per click regardless of which
         mode the device is in. Position attached to
         the button event uses the most recent active
         contact's last pixel position.
       - Per-report emission, no frame batching
         (Q1 design choice). Each Report ID 7 arrival
         produces exactly one event for one contact;
         frame structure is opaque to consumers.

     Verified bare-metal across multiple gestures:
     single-finger drag produced 1 type1 + ~110 type2
     + 1 type3 over ~900ms; two-finger drag produced
     interleaved per-contact-id type1/type3 cycles
     with continuous type2 emission; brief taps
     produced cleanly bounded type1/type2/type3
     sequences. Timestamps monotonic. No crashes
     across hundreds of frames.

  5. **Implement the feature-report send at attach
     time** to switch the device into Touchpad Mode.
     *Done 2026-05-06* (commit fb018da). The original
     plan had this targeting Report ID 12 (Surface
     Switch + Button Switch) but the ADR amendment
     of 2026-05-05 (commit 6386360) corrected this
     after review of FreeBSD's `wmt(4)` and `hmt(4)`
     sources: the load-bearing field is **Device Mode**
     (HUP_DIGITIZERS, HUD_INPUT_MODE, usage 0x52)
     which on the HAILUCK lives in Report ID 11.
     Setting Device Mode = 0x03 (Multi-touch Touchpad)
     enables Report ID 7 emission. Surface Switch and
     Button Switch are secondary controls that default
     to enabled; inputfs leaves them at defaults.

     The setter writes a full-rlen buffer (`rlen` from
     `hid_report_size`, including the report-ID byte)
     with `memset` + `buf[0] = report_id` +
     `hid_put_udata` + `hid_set_report(dev, buf, rlen,
     HID_FEATURE_REPORT, report_id)`. This pattern
     handles devices where Device Mode is packed into
     a larger configuration report alongside other
     fields without clobbering them.

     Failure is non-fatal: warning logged, attach
     proceeds, device stays in Mouse Mode. Verified
     bare-metal: dmesg attach line shows
     "Device Mode set to MT Touchpad (report_id=11
     rlen=2)" the SET_REPORT succeeded and the
     HAILUCK started emitting Report ID 7 immediately.

  6. **Verify scenarios 7-9 of the runbook end-to-end
     on the HAILUCK trackpad.** *Done 2026-05-06.*
     Operator session on `pgsd-bare-metal-test-machine`
     captured dmesg attach output (full chain present)
     plus inputdump traces for several gestures. The
     traces show correct contact lifecycle, per-contact
     tracking across overlapping gestures, monotonic
     timestamps, and per-report event emission at the
     ~125 Hz rate the descriptor declares. Phase 2.5
     status doc section 7 updated to "Verified" with
     this evidence; AD-2a Phase 2.5 multi-touch
     deferral entry closed.

     One small follow-up surfaced: inputdump's
     pretty-printer renders touch events as `touch.type1`
     / `type2` / `type3` rather than `touch_down` /
     `touch_move` / `touch_up`. Cosmetic, tracked
     separately as an inputdump symbol-table fix.
     The integrated clickpad button transitions
     weren't exercised in this verification session;
     a follow-up gesture test will cover that path.

**Documentation:** ADR 0018 (HUP_DIGITIZERS parser
design) plus its 2026-05-05 amendment captures the
Mouse-Mode-vs-Touchpad-Mode subtlety, the Device Mode
feature-report send at attach (Report ID 11, value
0x03, *not* Surface/Button Switch as the original
ADR draft mistakenly said; corrected after review of
FreeBSD's wmt(4) and hmt(4) sources), the
contact-ID lifecycle mapping to touch events, the
exclusive-HID-consumer architectural invariant on
which the single-attach pattern depends, the Q1
per-report emission policy, and the Q2 confidence-
low-as-tip-switch=0 policy.

**Out of scope for v1:** pen events (HUP_DIGITIZERS
usage 0x02), in-range without tip-switch (hover),
pressure, contact area. These map to additional
`pen.*` event types in `shared/INPUT_EVENTS.md` and
are tracked under AD-1's pen support sub-item, not
this one. Touch-screen variant (usage 0x04) is also
out of scope; the work is structurally similar but
requires touchscreen hardware in the lab.

**Effect on AD-2a:** *Closed 2026-05-06.* The
deferred Phase 2.5 multi-touch verification entry
no longer points to this sub-item as a blocker;
it points to the bare-metal verification evidence
above. Phase 2.5 closes on scenarios 1-6
independently; this sub-item allowed the deferred
7-9 to be verified. Phase 3 (deletions) is not
affected.

#### Sub-item: Apple multi-touch trackpad support *(Medium-Large)*

**Status:** open, parallel future work; not gating
Phase 2.5 multi-touch verification.

**Why this is separate:** Apple's Magic Trackpad family
(Magic Trackpad 1/2/3) does not use Microsoft Win8+
HUP_DIGITIZERS. It uses a vendor-specific multi-touch
protocol with custom report descriptors, Apple-defined
finger structures (4D coordinates including pressure
and finger angle), and a vendor-specific feature-report
write to enable raw multi-touch reporting (without
which the trackpad emits a basic mouse-class report
only). FreeBSD has limited prior-art for this hardware;
the relevant reference implementations are Linux's
`hid-magicmouse` driver and the older `bcm5974` driver
for built-in MacBook trackpads.

**Hardware target:** an Apple Bluetooth Magic Trackpad
is available in the lab but is not currently paired
with `pgsd-bare-metal-test-machine`. Pairing logistics
on FreeBSD (`hcsecd` configuration, link-key
persistence, reconnection handling) are part of this
sub-item's scope.

**Implementation outline (rough; finer scoping deferred
until prior-art reading is done):**

  1. Pair the trackpad with the test machine; confirm
     it attaches to inputfs via the Broadcom Bluetooth
     stack and capture its HID descriptor via the
     existing `hw.inputfs.debug_descriptor` sysctl.
  2. Identify which Apple multi-touch protocol variant
     the device uses (Magic Trackpad 2/3 are different;
     Bluetooth-vs-USB also differs).
  3. Implement the vendor-specific feature-report write
     to enter raw multi-touch mode.
  4. Implement an Apple-protocol parser variant
     alongside the HUP_DIGITIZERS parser, sharing the
     same `inputfs_digitizer_*` infrastructure for
     event emission.
  5. Verify scenarios 7-9 of the runbook on the Apple
     trackpad.

**Dependency on the HUP_DIGITIZERS sub-item:** the
shared digitizer infrastructure (classifier role,
event emission paths, contact-ID lifecycle handling)
should land first via the HUP_DIGITIZERS sub-item.
This sub-item then adds an Apple-protocol recogniser
that plugs into that infrastructure rather than
duplicating it.

**Effect on AD-2a:** none. The Phase 2.5 multi-touch
deferral entry closes on the HUP_DIGITIZERS sub-item
against the HAILUCK trackpad. This sub-item is
parallel future work that adds support for a second
hardware family.

#### Sub-item: pollable-fd / kqfilter for the events ring *(Small-Medium)*

**Status:** **superseded by AD-41.3 / ADR 0021, 2026-05-27 evening.**
The latency improvement this sub-item describes was delivered
by AD-41.3 via a different mechanism than this sub-item
proposed: a separate notification character device,
`/dev/inputfs_notify`, designed by ADR 0021 (Proposed
2026-05-25, implementation landed 2026-05-26/27). The notify
cdev provides full `d_poll` + `d_kqfilter` support
(verified in `inputfs/sys/dev/inputfs/inputfs.c:1556-1684`).
semadrawd's main loop adds the notify fd to its poll set;
when inputfs publishes an event, the notify fd becomes
readable and the daemon wakes. This achieves the same
latency benefit this sub-item described, while keeping the
data plane (mmap of `/var/run/sema/input/events`) decoupled
from the notification plane.

Closing this sub-item rather than implementing it: ADR 0021's
deliberate design choice was to use a separate notification
surface rather than fold kqfilter onto the data device, on
the reasoning that the data plane and notification plane have
different lifecycle and access patterns. Adding `d_kqfilter`
to the `/dev/inputfs` cdev as well would duplicate the
capability without a clear consumer; nothing in the codebase
opens `/dev/inputfs` and waits on it. If a future consumer
needs a single fd that combines data and notification, that
would be a fresh design decision (and likely a fresh ADR),
not a return to this sub-item.

**Previous content (preserved for the record of what this
sub-item was about before AD-41.3 superseded it):**

> Userspace consumers (`inputdump`, semadrawd's drain loop)
> poll the ring at an interval rather than blocking on event
> arrival. The poll-and-drain pattern absorbs events fine in
> practice with no measurable drop, so this is a latency
> improvement rather than a correctness gate. Plan: add
> `d_kqfilter` to the inputfs cdevsw, implement `EVFILT_READ`
> against the events ring's write index, fire knote on
> `inputfs_event_emit` completion. Half a day to a day of
> kernel work plus the inputdump CLI flag.

**Effect on AD-2:** none. AD-2 closed 2026-05-17,
independently of this sub-item.

### `[ ]` AD-4: Graphics output: replace efifb / DRM dependency  *(Open, Large; not scheduled)*

drawfs currently uses efifb (or DRM/KMS on capable hardware) for
display output. Both are accepted as platform transport today. Direct
GPU programming would be the largest dependency replacement UTF
could undertake.

This is the biggest scope item in the discipline's "in scope for
review" list. Vendor-specific GPU programming, command submission,
power management, and multi-vendor support make this a multi-year
undertaking even for a single vendor. Not scheduled.

**Design document (2026-06-08, operator-ratified):**
`drawfs/docs/AD4-NATIVE-OUTPUT.md`. It fixes the ownership principle
(UTF takes the broad scope, native GPU programming up through the
render engine, phased per vendor), the end-state model (native by
default and DRM/KMS-less by default, with drm as a backwards-
compatible tier and a firmware-framebuffer floor), the floor's own
long-term path (UTF's framebuffer obtaining the GOP directly; the
vt(4) and efifb kernel deprecation already delivered by AD-39, the
loader-provided GOP metadata the last borrowed piece, coordinated
with AD-11), the observation-first phase plan (Phase 0 through Phase
5), and the decisions that each become an ADR. Phase 0 (determine
display hardware via pciconf on each bench machine, add the native
backend tier, commit the first-vendor target) is the only step that
can begin without scheduling the program.


### `[ ]` AD-56: Boot-path ownership: replace FreeBSD's loader and menu with a fresh Awase loader  *(Open, Large; design ratified 2026-06-21; Phase 0 complete, Phase 0.5 design ratified 2026-06-24, Phases 2 and 3 scheduled as a program)*

Replace FreeBSD's loader.efi and its menu entirely with a fresh Awase
loader: the boot experience the firmware hands control to, the
framebuffer it runs on, and the loader engine that parses the kernel
and hands it off all become Awase's. This is the boot-side counterpart
to AD-4's "Awase owns the floor": AD-4 stops drawfs consuming the
loader-provided GOP metadata at the output layer; AD-56 replaces the
loader that provides it.

Operator decision (2026-06-21): the Awase loader is written FRESH, not
forked from loader.efi, so the kernel handoff, framebuffer ownership,
and boot UI are designed around Awase's model. Fresh-over-fork is a
principle, not a preference: it extends AD-4's floor ownership backward
into boot, so the display belongs to Awase from power-on to shutdown
with no ownership transitions that exist solely for historical FreeBSD
reasons.

**Design document (2026-06-21, operator-ratified with Objective
amendment):** `docs/design/BOOT-PATH-OWNERSHIP.md`.

**Ratified objective (the amendment):** the goal is NOT permanent
reproduction of FreeBSD's boot ABI. It is boot compatibility sufficient
to establish an Awase-native boot contract under joint control of the
Awase loader and the PGSD kernel. Awase owns both sides of the
boundary, so compatibility is a bridge, not the destination: document
the current ABI, implement compatibility, MEASURE what the kernel
actually consumes, define an Awase-native contract, remove the
compatibility layers over time.

**Risk concentration:** writing fresh relocates the program's danger
onto the kernel entry ABI (the modinfo blob, memory-map and
system-table handoff, GOP fields the kernel reads on entry). It is an
undocumented, version-coupled target; a wrong field panics or wedges
the kernel on a bench that then will not boot. The program is
structured to contain exactly that risk.

**Phases (observation first, fallback always reachable):**
  - Phase 0: observation, the stock-loader fallback entry, the ABI
    bridge document, and a tested recovery path. Five hard exit
    criteria (below).
  - Phase 0.5: ABI instrumentation. Modify the PGSD kernel to log what
    boot metadata it receives and which fields early init actually
    consumes. Measure, do not assume; likely shrinks the fresh loader.
  - Phase 1: own the menu inside stock loader.efi (pure script,
    reversible, zero bootability risk).
  - Phase 2: own the presentation and framebuffer, still inside stock
    loader.efi (the AD-4 seam).
  - Phase 3: the fresh Awase loader, split so a minimal handoff reaches
    init before any UI or native display contract is built on it (3a
    minimal handoff, 3b full modules, 3c fold in the UI, 3d
    Awase-native display contract, 3e AD-11 recovery integration).

    Phase 3 is under implementation as **AD-62** (`pgsd-loader/`): the
    fresh loader exists, L0 is closed, the kernel handoff contract
    (L3a.1) is complete, and the BAS kernel path (L3a.2) is
    bench-proven through the ELF loader. See the AD-62 entry below.

**Phase 0 exit criteria (hard gates, all five required):**
  1. Permanent fallback boot entry verified on real hardware.
  2. Boot-chain document produced.
  3. Kernel-entry ABI documented from source.
  4. Recovery procedure documented and tested (not just designed).
  5. A bench can always be returned to a known-good state without
     external media.

**Trust model / secure boot:** scheduled EARLY (decided before the
Awase-native contract, implemented late). Whether the loader verifies
the kernel, the kernel verifies modules, secure boot is
required/optional/unsupported, and whether recovery is allowed on
verification failure are terms of the boot contract, coupled to exit
criterion 5 (a brick-on-failed-signature model violates no-external-
media recovery).

**Relationship to existing work:** AD-4 (the GOP handoff AD-56's Phase
3d completes at the boot layer), AD-39 (already cleared vt(4)/vt_efifb
from the kernel; AD-56 clears the boot-side loader, which AD-39 did not
touch), AD-11 (AD-56's loader inherits AD-11's Alt-held recovery
trigger and respects its kernel-diagnostic-channel boundary).

**Startable now without scheduling the whole program:** Phase 0 and,
once its recovery criteria are satisfied, Phase 0.5. Each named
decision in the design doc becomes its own ADR before its code.


### `[ ]` AD-57: Source of truth for the PGSD kernel  *(Open, Medium; design ratified 2026-06-21, foundation for AD-56 Phase 0.5)*

Define the canonical representation of the PGSD kernel so it is
reproducible over time, independent of any artifact pipeline. Today PGSD
is a transformation (install stock FreeBSD with sources, run install.sh
to convert in place), so its kernel source of truth is "whatever is in
/usr/src" when install.sh runs, which drifts. AD-56 Phase 0.5 introduces
kernel instrumentation that MEASURES the boot ABI, and a measurement is
only meaningful relative to a specific kernel; an unreproducible
measurement defeats Phase 0.5's measure-not-assume premise. So a durable
kernel definition is a precondition of AD-56, not a consequence of a
future ISO goal.

This is a PROJECT-level decision (the project's representation of itself),
not a kernel-subsystem one: it affects AD-56, future kernel work,
install.sh, onboarding, and any later artifact pipeline.

**Design document (2026-06-21, DRAFT):**
`docs/design/AD57-PGSD-KERNEL-SOURCE-OF-TRUTH.md`.

**Scope:** development reproducibility only (reconstruct the exact kernel
used for a given investigation from the repo plus the pinned revision).
Artifact reproducibility (ISO/IMG, release tooling, publication) is
explicitly deferred to a later ADR that builds on this one.

**Four decisions:**
  1. Pinning: PGSD is defined against a specific FreeBSD source revision;
     "whatever is in /usr/src" ceases to be authoritative.
  2. Representation: the canonical kernel is {pinned upstream revision} +
     {ordered project deltas}, a recipe not a stored tree (preserves the
     derive-not-fork discipline; patch-storage mechanics deliberately out
     of scope so the ADR does not rot with tooling).
  3. Classification: deltas partition into definitional (part of PGSD)
     and investigational (transient research artifacts such as the AD-56
     instrumentation).
  4. Reconstruction: a developer can rebuild the exact kernel of a given
     investigation from repo contents plus the pin.

**Migration:** install.sh must move from "use whatever /usr/src is
present" to "use the pinned, patched kernel" (fetch the pin or verify
/usr/src matches it, then apply deltas). Real work; AD-56 is its
justification.

**Not vendoring the tree:** the recipe model gives a reproducible kernel
definition without turning the repo into a FreeBSD source mirror. Full
vendoring is rejected as the first move; whether any touched-file
patch-base is vendored is a representation detail, not this decision.

### `[~]` ADR 0002: the Awase artifact contract  *(In progress, Large; project-level ADR ratified 2026-07-10; milestone 1 of 5 complete and bench-verified 2026-07-10; milestone 2 next)*

**Tracks**: `docs/adr/0002-awase-artifact-contract.md`.

Building Awase and installing PGSD become independent systems that
communicate only through a published artifact contract: the successor
AD-57 explicitly deferred, the FREEBSD-PIN shape generalized from the
kernel to the whole substrate. Two principles graduate to project law
(Publish, Don't Infer; Authority Owns Truth), and the contract
converges on the Axiom artifact format (github.com/pgsdf/axiom), with
two enhancements flowing upstream: Lockbox-grade per-file inventory
promoted into package manifests, and identity/provenance separation.

**Milestones** (format before machinery; the implementation appears
once, at milestone 4):

- `[x]` 1. Kernel build separated from installation. Landed and
  bench-verified 2026-07-10 on both kernels: GENERIC (exit-3 gate,
  `--skip-kernel` acknowledgment, interactive notice, check/uninstall
  gate bypass) and PGSD (satisfied path). `install.sh` detects and
  informs, never builds; the kernel lifecycle is
  `pgsd-kernel-build.sh` per `pgsd-kernel/KERNEL-RECIPE.md`.
  Documentation updated (INSTALL.md Step 5.5, KERNEL-RECIPE.md
  ordering note).
- `[ ]` 2. Artifact contract established: the Awase build stages
  Axiom-compatible artifact sets with complete Lockbox-grade
  inventory and Merkle identity, inside this repository. Pure data,
  no runtime dependency on Axiom; closes the deploy-gap class
  structurally. **Next.**
- `[ ]` 3. `install.sh` consumes only the published contract:
  hash-verified inventory install, hard failure on divergence in
  either direction; the `BINARIES` list and all inferred
  completeness deleted.
- `[ ]` 4. Consumer implementation replaced by Axiom (store import,
  PGSD as a profile, realize and activate). Preconditions: Axiom
  exercised on the bench, and its FreeBSD 15.1 / Zig 0.16 migration
  done upstream. Only here does Axiom become load-bearing, as a
  deliberate operational decision.
- `[ ]` 5. Repository split along the proven contract; artifact sets
  referenced by identity, never committed to git.

**Findings originated in the milestone 1 bench session** (pending
operator disposition into their own AD numbers or existing entries):

- AD-8 first-gate miss (2026-07-10): buildkernel produced all ten
  suppressed HID `.ko` files despite `WITHOUT_MODULES`; the closure
  verification caught it at install time and the remediation path
  cleaned `/boot/kernel/`. Determine why the first gate missed
  (candidates: `resolve_without_modules` against the freshly pinned
  tree, or the variable not reaching the make invocation). P2.
- `pgsd-kernel-build.sh check` has no `/usr/src` ownership
  pre-flight: root-owned droppings from elevated git operations
  surface at fetch time instead of at `check`. Add a `[WARN]` when
  `/usr/src/.git` content is not owned by the invoking user. P2.

### `[~]` AD-62: pgsd-loader, the fresh Awase loader (AD-56 Phase 3 implementation)  *(In progress, Large; project ADR 0001 ratified; L0 closed, L3a.1 complete, L3a.2 through increment 2 bench-proven on bare-metal-test-bench)*

**F7 metal arming RETIRED (2026-07-11, ADR 0005 Decision 6).** The
armed transfer boots the pinned PGSD kernel to the mountroot prompt
in emulation (F7 root-caused: the loader now publishes the serial
console binding and, via findAcpiRsdp, the acpi.rsdp kenv the UEFI
kernel needs). On metal it does not: F7 reproduced on the bench's
Apple firmware twice, each requiring a FreeBSD reinstall. Metal
arming is retired; `deploy.sh` carries a deprecation header and its
`arm-once` refuses to run without a deliberate override. The open
F7 question, why the EFI handoff differs from QEMU (EFI runtime
mapping, SetVirtualAddressMap, memory-map handoff versus the stock
loader.efi), moves to emulation and source analysis; the bench is
not to be armed again to re-confirm a known failure.

**Tracks**: `pgsd-loader/` (the implementation), `pgsd-loader/docs/`
(the ADR series, the two bench-campaign ledgers, and the three
substrate specifications), and `docs/adr/0001-boot-artifact-deployment-architecture.md`
(the project-level deployment architecture).

The concrete realization of AD-56 Phase 3: the fresh Awase loader
the firmware hands control to, written fresh (never forked from
loader.efi) per the AD-56 operator decision. Where AD-56 is the
program and its phasing, AD-62 is the code and its bench evidence.
It advances by small, individually bench-proven increments under the
project disciplines (ADR-before-code, bench as sole authority,
forward-only history, operator ratification), and its central
methodological result inverts L0's flow: L0 built an implementation
and extracted architecture from the evidence; L3a observes the stock
implementation, extracts the contract, verifies the contract against
FreeBSD source, implements against the contract, and validates on the
bench, so the implementation is traceable to explicit requirements
rather than to resemblance.

**Stages.** L0 (presence and chainload) is closed. L1 and L2 are
scheduled but not started. L3a (BAS kernel path) is the live edge;
L3b (boot pool invariants) is gated behind it and cleared to design
by project ADR 0001. Each stage is its own ADR before its code.

**L0: presence and chainload (CLOSED, pgsd-loader ADR 0003).** The
loader proves it runs and hands control to the stock loader, with a
permanent fallback entry, verified across cold boots. The campaign
ledger (`docs/L0-BENCH-CAMPAIGN.md`) disposed eight findings; two of
them (F7, F8) would have shipped a non-booting primary under weaker
methodology, and F8's forensics (two lost FAT cluster chains of
exactly the loader size, metadata lost at fast poweroff while data
survived) produced the publication disciplines the BAS now enforces:
verify by read-back hash, no poweroff in the same breath as an ESP
write. Byte-identical rebuilds are pinned by SOURCE_DATE_EPOCH=0.

**Project ADR 0001 (RATIFIED): boot artifact deployment
architecture.** The project-level decision that governs how any boot
artifact is deployed: designated tooling is the sole writer; a named
authority triad separates content (build), publication (tooling), and
selection (operator plus policy) so nothing silently moves selection
into tooling; publication means publish-then-switch with
verify-in-place and provenance, or it is not publication; authority
is split so the loader, Recovery, and Maintenance environments live
in the Boot Artifact Store while the Operational kernel stays in its
ZFS system-image unit, matched to threat model; and recovery
invariants include verification-precedes-reliance (the prior path is
retained until the new artifact actually boots, the F7 lesson).

**L3a.1: the kernel handoff contract (COMPLETE).**
`docs/KERNEL-HANDOFF.md` is the amd64 EFI kernel handoff contract, the
stage's deliverable in place of code, organized by the kernel's
required contracts (kernel image, boot metadata, memory, firmware
exit, transfer, observable invariants) with every claim tagged
REQUIRED, OBSERVED, or VERIFY so incidental stock behavior never
hardens into imitation. A bench verification pass against the pinned
/usr/src resolved every VERIFY item; the sharpest, the trampoline's
salq shift of modulep before the kernel consumes it and kernend as
32-bit stack values, imposes the real below-4-GiB requirement on the
preloaded set. A single coordinate model (staging space, dest-space,
kernel virtual space) unifies the copy and no-copy staging regimes as
two realizations of one contract, and the handoff invariant states
it: every address exported to the kernel is expressed in dest-space,
and no staging address or loader-private translation crosses the
handoff boundary. The document is frozen to two sources of change,
new bench evidence or an upstream kernel contract change.

**L3a.2: the BAS kernel path (IN PROGRESS, ADR 0004).** Sequenced
tooling-first-minimal so the loader answers exactly one question at a
time. Done and bench-proven:
  - The Boot Artifact Store (`docs/BOOT-ARTIFACT-STORE.md`): a
    transactional publication substrate over FAT32 whose selector is a
    dual 512-byte record pair committed by a single sector overwrite
    of the losing record (ordering, not journaling), with a
    manifest-hash publication identity and a five-invariant frame
    (I1 through I5). One Zig source, `src/bas.zig`, is the single
    source of truth for the record bytes, imported by both the host
    publication tool and the loader read path so the two sides cannot
    drift.
  - Provisioning and section 7.4 publication (`tools/bas-provision.sh`,
    `tools/bas-publish.sh`, `src/bas_selector_tool.zig`): field-run on
    the real store, a known-good slot published (the running kernel
    plus drawfs.ko), the active-slot refusal (I1) fired on real
    hardware.
  - Increment 1 (the read and verification path): the loader resolves
    the active slot through the shared record code and verifies all
    three integrity layers before relying on the slot, then chainloads
    regardless (the safety property). Armed by file name, since the
    bench firmware cannot set boot-entry load options. CLOSED on metal:
    the verdict, recorded in a UEFI variable because this panel does
    not render console text, read back PASS on the real store.
  - Increment 2 (the ELF loader): parses the slot kernel's ELF64 and
    loads it into staging per the handoff contract, dest-space
    anchored at the image base, staging 2 MiB aligned below 4 GiB with
    slop past the image, segments placed with zero fill and no
    relocation. Verify-only (attest and free); proven in emulation in
    both directions, including a truncated image whose hash is
    legitimately correct so it passes all integrity layers and is
    refused only at the ELF layer. Its bench cycle is the immediate
    next step.

Remaining L3a.2 increments (each judged against KERNEL-HANDOFF.md,
never against loader.efi): the metadata chain (MODINFO with the
two-pass KERNEND self-consistency), the memory map and
ExitBootServices sequencing, the no-copy page tables and the
trampoline, then the first BAS-slot boot (multi-user plus drawfs plus
chime), followed by the two ADR 0004 closure campaigns (publication
under a power-interruption matrix, and the boot campaign with fallback
from a refused slot and a destroyed selector).

**The L3a campaign ledger** (`docs/L3A-BENCH-CAMPAIGN.md`) records the
bench findings under the L0 methodology. Three so far, all from
metal: F1 (this firmware consumes BootNext without honoring it), F2
(efibootmgr creates entries inactive, and an inactive order head sent
the firmware to an internal default rather than the next active
entry, on watch), and F3 (the console does not render on this panel,
disposed by the verdict variable, which also explains the
never-observed L0 banner).

**Relationship to AD-56, AD-57, AD-59.** AD-62 is AD-56 Phase 3
made real; AD-56 remains the program, the phasing, and the trust
model, and its earlier phases (menu and framebuffer ownership inside
stock loader.efi) are separate work AD-62 does not subsume. AD-57
(the pinned kernel source of truth) is the anchor the L3a.1
verification pass reads against. AD-59 (loader-stage recovery
reachability) is the policy layer that a future migration moves onto
this loader; project ADR 0001's split authority places the Recovery
environment in the same Boot Artifact Store AD-62 implements.

**Backlog items originated here:** AD-60 (audiofs path_dead_end flood,
from an L0 finding) and AD-61 (TxFAT32 extraction, deferred pending
L3a bench evidence) both below.

### `[~]` AD-59: Bootstrap recovery pipeline (loader-stage recovery reachability)  *(In progress, Large; design ratified through Part 15; pipeline validated end-to-end on hardware; the operator_recovery_request producer is done (Experiment 9); the Recovery binding producer remains)*

**Tracks**: `docs/design/AD59-*` (the fourteen-part design chain and the
experiment log in `AD59-PART3-BOOTSTRAP-EXPERIMENTS.md`) and
`pgsd-boot/lua/` (the implementation).

The recovery counterpart to the boot-path programs above. AD-56 owns the
boot path and AD-58 owns the verified-system lifecycle; AD-59 addresses a
narrower question those left open: a verified recovery boot environment can
exist and still be unreachable, because reaching it required memorized
loader syntax under stress. The recovery POINT existed; the recovery PATH
did not. AD-59 builds the path as a loader-stage pipeline that selects and
transfers to the correct boot environment without operator loader
knowledge.

**Mechanism (current) and portability.** Today the pipeline is a
`local.lua` extension the stock FreeBSD loader runs pre-menu (the
`try_include("local")` hook), so AD-59 owns POLICY, not loader mechanics.
The implementation is written migration-portable: the responsibility
structure is loader-agnostic and the loader-specific code is isolated to
the observation producers, so a future port into the AD-56 Awase loader
replaces only those. AD-59 and AD-56 are a layering, not a collision: one
recovery architecture, two implementation mechanisms (local.lua today, the
Awase loader later).

**The design (Parts 1 through 14, all ratified).** Part 1 fixes the
recovery contract (guarantees RG-1 through RG-6, "recovery precedes
administration"). Part 2 fixes the architecture: roles, policy, bindings,
selection, and the separation of the Operational and Recovery operating
environments. Part 3 is the experiment log. Part 4 derives the four
responsibilities. Parts 5 through 8 are the four responsibility contracts
(Discover, Decide, Bind, Transfer), each with positive and negative
obligations. Part 9 introduces the Loader Observation Model (LOM), the
stable, versioned, loader-derived observation boundary; Part 10 makes it
concrete (LOM v1 vocabulary plus a per-field producer table). Parts 11 and
12 fix the policy-evaluation semantics and Selection Policy v1. Part 13
fixes Bind's domain and dispatch (Bind resolves only unresolved roles;
Operational is already resolved). Part 14 fixes Transfer invocation (the
driver transfers only for a real transition) and the Experiment 8 safety
staging.

**Architectural separations (each corrects a specific coupling).** The
four responsibilities are one transformation each, ignorant of the rest:
Discover observes without interpreting, Decide interprets without
executing, Bind resolves without deciding, Transfer executes without
reasoning. The LOM is loader-derived (what the loader can observe), not
policy-derived (what a policy needs), so policy evolves without changing
Discover's interface. Policy is a separate artifact that `decide()`
evaluates, not logic embedded in `decide()`, so `decide()` is stable
generic infrastructure while policies evolve independently. The predicate
semantics make a concrete-value predicate false against an unavailable
observation, so the Operational default emerges by fallthrough rather than
a special case.

**The implementation (`pgsd-boot/lua/`).** `pgsd_bootstrap.lua` is the
portable module: `discover()` returns a versioned LOM v1 observation
object (unavailable fields explicit, never omitted); `decide()` is the
generic policy evaluator; `bind()` and `resolve_destination()` dispatch on
role; `transfer()` performs the redirect primitive once; `run()` is the
driver carrying the transition guard. `local.lua.example` is the thin
adapter; `local.8b.lua.example` is the Experiment 8b adapter; and
`deploy-loader.sh` deploys and verifies the pair atomically.

**Validation (Experiments 5 through 8b, all on bare-metal-test-bench).**
Experiment 5: `discover()` produces the LOM object. Experiment 6:
`decide()` evaluates Selection Policy v1 and selects a role. Experiment 7:
`bind()` and dispatch resolve a role to a destination. Experiment 8a: the
driver's transition guard correctly declines to transfer on the
no-transition (Operational) case, with the transfer primitive not invoked
(zero risk). Experiment 8b: `transfer()` performs a live boot redirect
through the complete production pipeline, redirecting the bench from its
selected environment to a known-good environment under single-boot
activation. The full pipeline (observation, policy evaluation, role
resolution, the transition guard, and the live transfer) is validated end
to end on hardware.

**The operator_recovery_request producer (done, Part 15, Experiment 9).**
The first of the two producers Experiment 8b simulated is now real. Part 15
fixed its contract (implementing ADR 0008 D4's loader-menu mechanism): the
loader environment variable `pgsd_recovery_request`, set to "1" on operator
request, read by `discover()` and mapped to `present` (unset maps to
`absent`). `discover()` implements the producer, and a minimal loader-menu
affordance sets the variable; comprehensive menu ownership remains AD-56's,
which will set the same contract. Experiment 9 validated both mapping paths
on hardware: a real operator recovery request produced `present` and the
Recovery Role and a live transfer, and no request produced `absent` and the
Operational Role and no transfer. The trigger is no longer simulated; an
operator can now invoke recovery.

**What remains (the entry stays `[~]`, not `[x]`).** Making the second
producer real is the outstanding work, and it is additive (the validated
pipeline selects and transfers unchanged once it arrives):

  - The Recovery binding producer: the AD-58 promotion write path writing
    a real, loader-readable role-to-environment binding. Part 2 fixes the
    promotion authority as the owner; the write mechanism is unbuilt. Until
    it exists, a bench exercise of the Recovery path still supplies a
    temporary binding for the destination (as Experiments 8b and 9 did);
    the trigger is real, the binding is not.
  - `promotion_state` and `boot_generation` producers: the other two
    unavailable LOM fields, each needing a source, enabling richer
    policies (health inference, rollback) beyond Selection Policy v1.

  A recorded observation for the eventual AD-56 loader migration
  (Experiment 9): the transfer primitive's `config.reload()` re-triggers the
  loader's local.lua hook in the destination environment's context, so a
  production hook must not blindly re-run the full pipeline after a transfer.
  Harmless today (the destination lacks the module, so the re-run fails
  gracefully); a design input when the pipeline moves into the Awase loader.

**Relationship to AD-11.** AD-11 is the recovery architecture at the
session layer; AD-59 realizes recovery reachability at the loader stage,
ahead of it. AD-11's D4 loader-stage trigger is precisely the
`operator_recovery_request` producer AD-59 awaits. AD-11's entry predates
the Operational/Recovery environment framing AD-59 established; a fuller
reconciliation of AD-11's session-posture language with that framing is
flagged as future documentation work, not a blocker.

### `[ ]` AD-11: Console and recovery: pgsd-sessiond as universal login surface  *(Open, Medium; reframed 2026-05-21)*

**Tracks**: a future ADR (AD-11.1 below) and three small
mechanism sub-items. Depends on SM-1 (`pgsd-sessiond`)
already done; depends on rc.d service-lifecycle infrastructure
from AD-12 already done.

**Reframed 2026-05-21 under "convergent paths" model.** The
previous AD-11 framing (kernel-side console replacement,
`consfs`, drawcons design ADR, kernel-side panic rendering)
contemplated a much larger commitment than necessary. The
reframed AD-11 is small and stays inside UTF's existing
substrate: every path that today ends at a `vt(4)` ttyvN
shell instead ends at `pgsd-sessiond`'s login prompt
rendered through drawfs, on the same input substrate
(inputfs) and the same display substrate (drawfs) UTF
sessions normally use.

**Three convergent paths, one endpoint:**

  1. **Normal bootstrap.** Standard rc.d ordering completes;
     `pgsd-sessiond` starts and presents the login prompt.
     User logs in as their normal account into a normal
     UTF session. No change from today.

  2. **Operator-selected recovery (Alt held during bootstrap).**
     The loader or early rc.d stage detects Alt held at a
     known point in boot. Instead of the normal session
     profile, rc.d selects a recovery profile: minimal
     services started, recovery tools on PATH, defaults
     biased toward root login. `pgsd-sessiond` still
     presents the login prompt; user logs in (typically
     as root) and recovers. The recovery session is a
     normal UTF session with a different startup profile,
     not a separate console layer.

  3. **Auto-recovery (panic or detectable bootstrap failure).**
     On boot the system reads a persisted "last boot did
     not complete cleanly" marker (NVRAM, `/boot`, or a
     marker file on a known-good filesystem). If present,
     bootstrap selects the recovery profile automatically,
     same as if Alt were held. The marker is set by the
     panic handler before reboot, by detectable rc.d
     failures (ZFS import fails, critical service refuses
     to start), or by user action ("reboot into recovery
     next time"). The marker is cleared once a recovery
     session is started, so the *next* normal boot is
     normal again.

  Use cases for path 3 include not only failure recovery
  but routine administration: changing boot environments,
  rolling back a ZFS BE, repairing a configuration that
  produces a broken normal session. Recovery is a normal
  mode of operation that users choose, not only a state
  the system falls into after breakage.

**What this commits UTF to owning:**

  - Detection of the recovery condition at three trigger
    points (Alt at boot, persisted marker, detectable
    failure during bootstrap).
  - A recovery session profile, selectable by rc.d or
    `pgsd-sessiond` based on the trigger.
  - The persisted-marker mechanism, including who writes
    it (panic handler, failing rc.d scripts, user-invoked
    "reboot into recovery") and when it clears.

**What this commits UTF NOT to owning:**

  - Kernel-side text rendering for panic messages. If the
    kernel panics during a window where drawfs is not yet
    up (very early boot) or where the panic prevents
    reboot (extremely rare), there is no UTF console to
    display the message; the operator's path is to boot
    from external media. This is the same posture FreeBSD
    GENERIC takes when `vt(4)` cannot initialise.
  - A `getty`-equivalent or TTY-like session abstraction.
    `pgsd-sessiond` is the login surface; UTF sessions are
    the post-login environment. Job control, line
    discipline, and other TTY semantics are provided by
    the shell process under the session, not by UTF
    itself.
  - Owning the boot console messages from the FreeBSD kernel
    before drawfs loads. Those continue to go to wherever
    FreeBSD writes them. On a PGSD kernel with AD-39's
    compile-out, there is no console-on-framebuffer driver
    to receive them, so they have no on-screen destination
    until `drawfs.ko` loads; messages still reach the dmesg
    ring buffer and any configured serial console. (Pre-AD-39
    kernels with `vt_efifb` compiled in put boot messages on
    the framebuffer via that driver; PGSD does not. There is
    no separate `efifb` driver in FreeBSD distinct from
    `vt_efifb`. The previous wording of this entry, which
    implied one, was wrong; corrected 2026-05-27 evening
    after audit.) UTF replaces the *user-facing* console,
    not the kernel's own diagnostic output channel.

**Sub-stages:**

- **AD-11.1**: write the ADR. Position UTF's recovery
  posture explicitly. Settle the persisted-marker
  mechanism (where does the marker live, who can write
  it, when does it clear) and the Alt-detection
  mechanism (loader-level via kenv, or early rc.d via
  inputfs reading a designated key, or some other
  approach). Document the explicit non-commitment to
  kernel-side panic rendering and the external-media
  fallback for unrecoverable cases.
  DRAFTED 2026-06-08 as pgsd-sessiond ADR 0008
  (Proposed, awaits operator ratification). It settles
  both mechanisms: the marker is /boot/utf-recovery with
  a self-resetting boot-progress field (auto-detection by
  inversion, no panic-context write) plus a separate
  explicit-request field cleared on recovery-session
  start; Alt detection lives in early rc.d over inputfs,
  with a loader-menu kenv complement for the pre-inputfs
  window. The ADR refines this entry's assumption that
  the panic handler writes the marker (a panic-context
  persistent write is unsafe; the in-progress state left
  behind is the signal instead).

- **AD-11.2**: implement the bootstrap-time trigger
  mechanism. Alt detection plus marker-file read; both
  resolve to a single boolean visible to subsequent
  rc.d stages and to `pgsd-sessiond`. Bench-verified
  by holding Alt at boot and observing the recovery
  profile activate.

- **AD-11.3**: implement the recovery session profile.
  An rc.d profile variant plus a `pgsd-sessiond`
  configuration that adjusts defaults. Bench-verified
  by activating recovery via Alt and via marker, and
  confirming the session behaves as designed (recovery
  tools on PATH, minimal services, root login pre-
  selected if that is the chosen design).

- **AD-11.4**: implement the marker-writing paths.
  Panic handler hook to set the marker before reboot.
  rc.d hook to set the marker on detectable failure.
  User-invoked `reboot-into-recovery` command to set
  the marker explicitly. Marker-clearing once a
  recovery session is started.

- **AD-11.5**: bench verification across the three
  trigger paths. Hold Alt at boot. Boot from a normal
  session with a deliberately broken config to trigger
  rc.d failure path. Trigger a panic (using existing
  panic-injection mechanisms from AD-9 fuzz harness)
  and verify the next boot enters recovery
  automatically. Confirm that an operator-initiated
  `reboot-into-recovery` does the same.

**Asymmetry vs the previous AD-11 framing**: the old entry
contemplated kernel-side console rendering, a `consfs`
substrate, and panic-resilient text output. Those
commitments would have made AD-11 the largest single piece
of work in the UTF backlog. The reframed AD-11 stays
inside the session layer where UTF already operates; the
new work is detection, profile selection, and a small
persisted-marker mechanism. Estimated scope drops from
Large to Medium.

**Discipline framing**: the original AD-11 entry argued
that `vt(4)` competing with UTF surfaces during boot is
the kind of "external code that does not share UTF's
commitments" the discipline doc warns about. That
argument applies to the **post-boot, post-drawfs-loaded**
console, not to early-kernel-printf or panic messages.
The reframed AD-11 owns the former and explicitly does
not own the latter. UTF treats early-kernel and panic
output as platform transport, the same posture inputfs
takes toward early-boot keyboard input via `kbdmux`
before inputfs attaches.

**Depends on**:

  - **SM-1** (`pgsd-sessiond`): already done. AD-11
    extends SM-1's session-profile machinery; no new
    dependency burden.
  - **AD-12** (service lifecycle): already done. AD-11's
    recovery-profile rc.d work fits inside the existing
    service-lifecycle conventions.
  - **AD-39** (kernel console drivers compiled out):
    already done. AD-39 removed `vt(4)` from PGSD; the
    "compete for framebuffer" failure mode no longer
    exists. AD-11 is not about reclaiming the framebuffer
    from `vt(4)` (AD-39 did that); it is about giving
    operators a recovery path on a UTF-owned display.

  (The previous AD-11 entry listed AD-10 as a dependency.
  AD-10 was superseded by AD-39 on 2026-05-13; the
  reframed AD-11 depends on AD-39 instead. AD-4 graphics
  output replacement is no longer a partial dependency
  because the reframed AD-11 does not contemplate
  kernel-side console rendering.)

**Risks** (much smaller than the previous framing):

  - **Marker placement and clearing**: a marker that
    sticks across reboots permanently traps the system
    in recovery mode. The clearing logic must be
    correct: clear on entering a recovery session, not
    on completing one (so an unclean exit from recovery
    still leaves the marker valid for retry).
  - **Alt-detection placement**: too early (loader
    level) means a separate keyboard path that doesn't
    use inputfs; too late (post-`pgsd-sessiond`) misses
    boot failures that prevent reaching that stage. The
    ADR settles where this lives.
  - **Recovery session itself being broken**: the
    recovery session uses the same drawfs and inputfs
    substrate as normal sessions. If those are broken
    badly enough to prevent rendering a login prompt,
    AD-11 cannot help and external media is the
    answer. This is acknowledged in the ADR rather
    than worked around.

**What this entry does not claim**:

  - It does not claim `vt(4)` is broken. `vt(4)` works
    correctly within its design; PGSD has removed it
    only because UTF does not need it as a session
    console once SM-1 and AD-11 are both in place.
  - It does not commit UTF to owning the boot console
    (early kernel printf), the panic console (KDB output
    post-fault), or the system console of last resort.
    Those remain platform transport, like inputfs's
    treatment of early `kbdmux` keyboard.
  - It does not commit to taking over single-user mode
    in the FreeBSD-init sense. Single-user mode is
    superseded by the recovery session profile;
    operators who need a recovery shell get one via
    path 2 or path 3 above.

**Historical record**:

  - **2026-05-04**: AD-11 first discussed, prompted by
    AD-10 framing. Original scope was "should UTF own
    the console itself, on the same discipline grounds
    that motivated inputfs / drawfs / audiofs?"
  - **2026-05-10**: Option Y decision. UTF commits to a
    native login and session path (SM-1) but does not
    commit to kernel-side console takeover. AD-11
    becomes "retire `vt(4)` even for recovery" as a
    narrower question.
  - **2026-05-13/14**: AD-39 lands. `vt(4)` is compiled
    out of the PGSD kernel entirely. The "compete with
    `vt(4)` for the framebuffer" problem evaporates by
    construction.
  - **2026-05-21**: AD-11 reframed under the "convergent
    paths" model. Recovery becomes a session profile,
    not a separate console layer. Scope drops from
    Large to Medium. This entry as currently written
    replaces the previous Option-Y entry.


### `[ ]` AD-52: clickpad discrete button events unreliable; sc_touch_prev_button latches  *(Open 2026-06-08, carved from AD-27; input; Small-Medium; ADR before code)*

Found while benching AD-27's button path on pgsd-bare-metal (the
HAILUCK touchpad has separate physical buttons, not a click-anywhere
surface). Motion and the held-button-during-drag state are correct;
the discrete pointer.button_down / button_up events are not.

Observations across four root-run benches (scripts/ad27-cursor-verify.sh):
  - button_down emitted exactly once, on the first-ever press.
  - button_up never emitted.
  - the button STATE is read correctly: during a drag the held
    button shows as buttons=0x1 on every motion record.

Mechanism (code-level, inputfs.c). The button block at 3509 emits on
`btn != sc->sc_touch_prev_button` and runs only when a Report 7 is
dispatched (the touch dispatcher). sc_touch_prev_button (declared
723, M_ZERO at attach) is assigned in exactly one place (3546) and
is never reset on contact-end / all-fingers-up. So:
  - first press: btn 0->1, transition, button_down, prev := 1;
  - if the release's 1->0 is not carried by a dispatched Report 7
    (release coincides with loss of contact, so no Report 7 with
    btn=0 is generated), prev stays 1 permanently;
  - thereafter every press reads btn==prev==1 (no button_down) and
    button_up never fires.

Confirming observation still wanted (does not block filing): a live
`inputdump events --watch --role pointer --device <slot>` while a
finger keeps moving on the pad through a deliberate button
press-and-release, to see whether button_up fires when a btn=0
Report 7 is guaranteed to flow. If it does, the defect is purely the
contact-end case; if it does not, the latch is broader.

Fix direction (for the ADR, not yet ratified): reset
sc_touch_prev_button when active contact count reaches 0 (and/or
synthesize a button_up on contact-end if the button was held),
and/or evaluate the button transition on the mouse-mode (Report 1)
path as well, so button state does not depend solely on Report 7
flow. ADR before code, per project discipline.

ADR drafted 2026-06-08: `inputfs/docs/adr/0022-clickpad-button-event-reliability.md`
(Proposed). It pins the mechanism (prev set only at 3558, reset
nowhere; `extract_digitizer` does not drop a `btn=0` report, so the
fault is the unconditional dependence on a `btn=0` Report 7 reaching
the block), promotes the confirming observation to a decision input
(does `button_up` fire under guaranteed `btn=0` flow), and branches:
D2 a guarded contact-end safety (Outcome 1) and D3 tracking the button
independent of Report 7 flow via the Report 1 path (Outcome 2, and the
recommended durable remedy).

Observation run 2026-06-08 (two root captures, finger sliding through a
mid-slide release): Outcome 2 confirmed. With Report 7 flowing for 10.6
seconds past the press, one `button_down`, zero `button_up`, state
`buttons` latched at 0x1; the release is unobserved on both the
digitizer and Report 1 paths the pointer watch covers. D2 eliminated
(no `btn=0` in the flowing stream to act on); D3 selected. An attach-log
diagnostic (touch versus Report 1 button locations) is added at
inputfs.c to pin which report carries the release; D3 is finalized after
that diagnostic and the button-alone-no-finger bench. ADR 0022 remains
Proposed until then.


### `[~]` AD-49: new connects refused while semadrawd served existing clients  *(WATCH, Small; downgraded 2026-06-06 evening: present health proven, residue unresolvable retrospectively, reopen on recurrence)*

ORIGINAL PREMISE FALSIFIED, owned: the five boots read as a
crash loop were the afternoon's deliberate restarts sitting in
one sparse log file (the flag removal made current span hours).
The death-time extraction maps every boot to an operator
action: the SM-4 install (~16:32), the AD-40 bench legs
(~16:51, ~16:58 twice), the AD-48 install (~17:17), the reboot
(~17:34). No crash ever occurred; /var/log/messages and the
absence of cores agree.

THE REAL ANOMALY: in boot 5's window the log shows client 2
(peer uid 1001, the operator's terminal) connecting and
completing its handshake at ~17:25, the daemon then running
continuously until the reboot, while the operator's truss in
between shows fresh connects to /var/run/semadraw.sock
returning ECONNREFUSED. A live daemon serving existing clients
while the socket file refuses new ones. The term's 17:25
connection died again somewhere in the window (client
disconnects are structured events, invisible to the non-event
greps used so far). The reboot destroyed the live state;
surviving evidence is the structured event stream of boot 5.
Probes issued: client_connected/client_disconnected events in
the boot 5 line range (what killed client 2, when, and with
what reason field), and the location of the AD-20 finish lines.

BREAKTHROUGH (2026-06-06 evening, the three events of boot 5):
client 1 (peer uid 0) is the post-install sessiond connecting
at 17:25:25, so the LOGIN SCREEN WAS LIVE through the refused
window, never frozen. Client 1 disconnects at 17:26:46 with
reason "disconnect", a clean close: sessiond's normal login
handoff (the operator logging in). Client 2, the retrying
terminal, connects 55 MICROSECONDS later, before the reboot:
AD-40 vindicated a second time, the reconnect succeeded on its
own. The anomaly's precise statement: semadrawd refused new
connects for the ~80 seconds that the login screen was its sole
client, and accept resumed the instant that client departed.
The 55 microsecond coupling says something serializes accept
against the login-screen client's presence; backlog exhaustion
from starved accepts is the textbook way a live daemon returns
ECONNREFUSED. Asymmetry noted in passing: the old finish lines
DID reach pgsd-sessiond's log but not semadrawd's, an fd
inheritance difference worth one look, and sessiond's recorded
exit codes from the install window sit in that file.

REPRODUCTION BENCH (the condition is just "login screen up,
nothing else connected"; needs a second access path, ssh or
another console):
  (1) log out to the login screen;
  (2) from ssh: nc -U /var/run/semadraw.sock < /dev/null;
      echo $?   (refused reproduces the bug; connected refutes
      the hypothesis and the hunt widens);
  (3) if refused: sudo truss -p $(pgrep -x semadrawd) for ~3 s
      captures whether the loop is turning, whether poll
      includes the listen fd, and whether accept ever fires;
      a loop blocked in one syscall names the serializer
      outright;
  (4) log in; repeat (2) immediately; expect connected;
  (5) sessiond's death records from the install window, free
      data: grep "finish: exit" /var/log/utf/pgsd-sessiond/current | tail -8

PROBE SESSION 2 (2026-06-06, post-reboot) AND A NEW SUSPECT:
three nc probes against the same socket produced three outcomes
(clean exit 0, an indefinite hang, and a self-reaping
background job), the fd assignments CHANGED between two trusses
of "the same" daemon (impossible for one process), and the
login screen spontaneously refreshed mid-probe: the
parsimonious reading is that semadrawd restarted underneath the
probes. New hypothesis: a connect-then-immediate-EOF client, a
shape no real UTF client has, kills or wedges the daemon via
the handshake path's EOF arm, and the refused windows may
reduce to corpses left by the probes themselves. SM-4 noted in
passing: the wrong-password retry message rendered correctly.

scripts/ad49-probe.sh (NEW) runs the controlled experiment: the
daemon's pid, uptime, boot count, and client_connected count
captured BEFORE, exactly one bounded connect-and-EOF (nc -w 2),
and the same captures AFTER, with a five-way verdict: daemon
died (pid changed), daemon restarted (uptime reset), healthy
(accepted, event emitted, survived), accept starvation (nc
exit 0 with NO client_connected event: the connect sat
unaccepted in the backlog and the EOF close was mistaken for
service), or refused/timed out with the daemon alive. The
operator notes the screen state alongside the paste; the
finish-line logging deploys with the next install and will
make any further deaths self-documenting.

EXONERATED AT SYSCALL LEVEL (2026-06-06, two operator-captured
truss-plus-fdmap sets): both probes ran against the same daemon
(pid stable across tests), and test 2 documents the probe
client's complete life: accept4 the instant poll reports the
listener, the connect logged, two hundred lines of normal loop,
then read returning 0 (the EOF), a client_disconnected event,
a clean close, and the loop rolling on into render work. Test 1
shows the identical pattern. The connect-and-EOF hypothesis is
DEAD; probe session 2's anomalies dissolve with it (the
self-reaping nc was normal completion; the missing
client_connected was a tail -3 window too shallow, this saga's
recurring observation sin; the fd-order reading loses its only
corroboration). Found in passing: the render path is
synchronous request/reply per operation against /dev/draw
(write, poll with a 5 s ceiling, read), during which accepts
wait; a real serializer, but at measured op rates it explains
milliseconds, not the original eighty seconds.

PROPOSED DISPOSITION: DOWNGRADE to Open, Small,
watch-for-reproduction. The original refused window stands:
real, bounded to ~80 s during install churn in boot 5,
witnessed by truss, terminated to the microsecond by the login
handoff, and unexplained. It does not reproduce on current
code under either screen state, and the watch instruments are
now in place: finish logging on the next install makes deaths
self-documenting, the sparse logs make boot counting honest,
and scripts/ad49-probe.sh is the standing five-verdict probe
for any recurrence. The accept-while-rendering serialization
is recorded as the one known mechanism in the daemon that can
delay accepts at all, a thread to pull if the window ever
returns.

PROBE V1 VERDICT (2026-06-06 20:06, operator's session, logged
in): ACCEPT STARVATION CONFIRMED LIVE. Same pid before and
after (4515), uptime climbing, nc connected (exit 0), and zero
client_connected events across the ~2 s the connection sat
queued, roughly twenty poll cycles' worth of chances. The boot
counter corroborates the probe-session-2 deaths: 9 boots in
current against the 6 accountable this morning. The condition
reproduces while logged in, so the login-screen binding from
the original incident was circumstance, not cause. Remaining
fork, two mechanisms: poll reports the listener ready and the
dispatch never converts it to an accept (userspace, the recent
edit region), or poll stays silent with a connection queued
(the fd-3-is-the-listener inference wrong, or queue-semantics
surprise). ad49-probe.sh v2 discriminates in one run: procstat
maps the fds definitively, and a truss spans the nc window,
with the verdict computed from poll-ready count versus accept
count.

PROBE V2 VERDICT (2026-06-06 20:16): THE DAEMON IS HEALTHY, and
v1's starvation verdict is RETRACTED as my script's error. The
in-window trace shows poll ready, accept4 on the listen fd
(procstat-confirmed fd 3), the "client 6 connected" info line,
and the new fd entering the poll set: accept, dispatch, and
admission all work. The zero structured-event delta that drove
v1 was the wrong signal: client_connected carries handshake
version fields and fires only after a HELLO, which nc never
sends; no nc probe can produce one. The fd map also decodes the
earlier puzzles: fd 8 is the terminal's live accepted
connection (quiet at idle, hence poll's honest timeouts), and
"client 6" means six accepts this incarnation, all serviced.
The probe script's verdict logic is corrected (accepts in the
trace are the truth signal).

DISPOSITION, DOWNGRADE TO WATCH: every controlled test shows
present health. The residue: boot 5's 81 second refusal window
(real, truss-verbatim, retrospectively unresolvable: the term
connected cleanly at 17:26:46 and the circumstance has not
recurred) and boots 7 and 8's undocumented deaths during probe
session 2 (pre-dating the finish fix). The finish logging
deploys with the next install and makes any future death
self-documenting; ad49-probe.sh v2 is the standing instrument.
Reopen on recurrence; until then this entry blocks nothing.

FOUND IN PASSING (AD-20 observability gap, fix regardless):
the finish script logs death records to stderr, which in an s6
finish goes to the supervisor's console, not the service's log
pipe; the script's own comment claims operators see these in
/var/log/utf/<name>/, which is false. Every exit code and
signal AD-20 has ever recorded went somewhere nobody looks.
The fix is one line: log to stdout, which s6 connects to the
service's logger. This incident cost an hour that one visible
exit code would have saved.

The observability fix is IMPLEMENTED (2026-06-06): all four
finish copies (the template and the three per-service files)
log to stdout, with the incident history in the comment; five
pre-existing em dashes per file cleaned per house rule. Deploys
on the next install. Bench: after any service exit, the
"finish: exit=N signal=N lifetime=Ns" line must appear in
/var/log/utf/<name>/current.

BENCH PRIMARY GREEN (2026-06-07 install plus controlled
semasound bounce): the finish line lands in the service log,
"semasound: finish: exit=0 signal=0 lifetime=0s". The values
exit=0 signal=0 are CORRECT for this daemon (semasound catches
TERM via its stop flag and exits cleanly; the predicted 256/15
applies only to daemons that do not catch TERM, prediction
error owned). TWO ANOMALIES OPEN:
  (1) lifetime=0s for a daemon that ran for minutes. The
      marker write exists in all three run scripts and resolves
      to the correct path; the finish read resolves to the same
      path (its claimed 4-arg s6 interface is doubtful, but $3
      unset falls back to pwd, the service dir). Both ends hide
      behind silencers (2>/dev/null || true on the write, the
      else lifetime=0 fallback on the read), so the on-disk
      marker is the only witness. THE STAKES: lifetime 0 makes
      every death a fast crash, and five benign bench restarts
      inside 45 s would trip flap protection and mark the
      service down, the opposite of AD-20's purpose.
  (2) two identical finish lines for one s6-svc -r.
Probes issued: the marker's existence and epoch against date
+%s (discriminates write-fails vs read-fails vs rewritten),
the crash log's accumulated count (distance to the flap edge),
and the interleaved finish/fast-crash lines (one death or
two).

PROBE VERDICT AND A FOUNDATIONAL FINDING (2026-06-07): FLAP
PROTECTION HAS NEVER FUNCTIONED. Every finish invocation prints
"supervise/ missing on this finish invocation; skipping flap
accounting": the AD-20.3 early-boot guard has fired on every
death since AD-20 shipped, no crash log has ever been written,
and the lifetime always read 0 from the same root. The root:
finish resolved the service dir as "${3:-$(pwd)}", and the
first verification run amended the mechanism my refile had
asserted: $3 arrives SET, to a value that is not the service
directory, so the bad expansion won and the pwd fallback never
engaged at all (the working directory for finish IS the service
dir on this system, proven by the relative marker path resolving
and by basename printing "." once the first fix landed). The
scan-dir claim in the earlier version of this record was wrong
and is corrected here. The run-side marker write survived by accident:
it resolves via dirname "$0", which is correct under either
working directory (the marker probe proved it: sane epoch 258 s
before the operator's date +%s). FIXED in all four finish
copies: SVCDIR derives from $0 resolved ABSOLUTE (cd plus pwd),
correct under any working directory and any argument
convention, and restoring the real service name to the log
lines (the first fix's relative "." printed ".: fast crash"). Retro-corrections recorded: every
incident-era theory invoking "flap backoff held the daemon
down" was formally impossible, flap never engaged once; the
silver lining is the giveup never falsely triggered either.
The third finish line in the log is noted with a benign
hypothesis (the install's tree-refresh choreography bouncing
the service); working lifetimes will make future counts
self-explanatory.

FIRST VERIFICATION RUN (2026-06-07 10:01 JST): leg 1 PASS,
lifetime 3732 s exact against the marker with the guard silent,
the SVCDIR fix proven. Leg 2's machinery worked (counter
climbed 1/5 then 2/5 on cue) but the script died on its own
count() helper: grep -c prints 0 AND exits 1 on zero matches,
so the || echo 0 fallback double-emitted and poisoned the
arithmetic. Helper fixed (capture, then default on empty). The
".: fast crash" prefix exposed the relative-path name bug fixed
above. No bench-state hazard: the two crash-log epochs age out
of the 45 s window and the rerun's leg 1 truncates them.
Redeploy the finish copies (cp loop) before the rerun.
Second run blocked by the verify script's own precheck, which
still grepped for the superseded relative SVCDIR pattern and so
rejected the correct deployment; pattern updated to a fixed
string match on the absolute line. The failed precheck was
itself confirmation that the deploy landed.

BENCH GREEN, THREAD SETTLED (2026-06-07 14:04 JST, all three
legs PASS): leg 1 lifetime 1975 s exact against the marker with
the guard silent; leg 2 counter at 1/5 then 2/5 with two epochs
in the crash log and no giveup, the restored service name
visible in the lines themselves; leg 3 crash log truncated
empty by the long-lived reset (lifetime 51 s). Flap protection
is operational for the first time since AD-20 shipped. The
45 s prune branch stays verified by inspection. The AD-20
chain that began as a one-line stdout fix inside this entry,
and burrowed through four layers of silencers to a safety
system that had never run, is closed.

Bench record, scripts/ad20-flap-verify.sh
encodes the three legs with pass/fail verdicts and a deployment
precheck (the fixed finish can be cp'd directly into
/var/service, no install needed: finish scripts are read fresh
at each death). Leg 1: one bounce, lifetime equals the true
seconds since start with the guard silent. Leg 2: two bounces
3 s apart, the counter climbs 1/5 then 2/5 with two epochs in
the crash log, and the script deliberately STOPS there, three
more would trip the giveup. Leg 3: a 50 s wait then one bounce
truncates the crash log (the long-lived reset branch). The
45 s prune branch stays verified by inspection, same arithmetic
shape as the reset. All against semasound, self-recovering per
AD-47.


### `[x]` AD-50: AD-47 null_sink never recovers (leaked fd deadlocks reconnect against exclusive open)  *(CLOSED 2026-06-20, operator-ratified; root caused in code, single-owner DeviceFd fix implemented, compile-verified, and bench-ratified the recovery path)*

This is the bug AD-47 left behind. AD-47 stopped the engine dying
on a device write error by transitioning real to null_sink and
adding a once-per-second reconnect. The reconnect can never
succeed, so the engine survives but is permanently degraded:
holding the device open, feeding it nothing, underrunning every
fragment forever.

Bench shape (2026-06-19, observed twice across two semasound
processes): an output stream live on controller 0's Speaker DAC
(state region runtime_active=1, current_format=0x0011; clock
clock_valid=1, samples advancing), unfed, with
dev.audiofs.0.underflow_count climbing about 47 per second.
semasound alive and idle, holding /dev/audiofs0 fd open with no
connected client, output thread timer-pacing in null_sink. The
condition recurred on a fresh process within hours, so the trigger
fires in ordinary operation, not as a one-off.

MECHANISM, confirmed in code (not inferred from the vanished live
state, which truss and procstat kept perturbing into exit):

  - output.zig real-state write error transitions to null_sink but
    did NOT close the failed fd. The AD-47 comment at the fd
    declaration was explicit and was the defect: "Dead fds are
    never closed (a bounded leak per device-loss cycle), so no
    reader can race a close." The leak was a deliberate choice to
    avoid a close-race with the accept path's election ioctl.

  - audiofs is exclusive-open: audiofs_cdev_open (audiofs.c:5588)
    returns EBUSY while output_stream_cdev_open is set, cleared
    only in cdev_close. While the leaked fd is held, the flag stays
    set.

  - So null_sink's once-per-second openWronly(DEVICE_PATH) returned
    EBUSY every time: semasound blocked its own reconnect with its
    own held fd. It could never return to real. Discards the mix,
    never feeds the held stream, underruns forever.

  - Trigger: a normal client connecting at a new rate runs the
    accept-path election (applyElection then SET_FORMAT, ADR 0019),
    which reconfigures the live stream and wakes the blocked writer;
    that woken write returning an error flips real to null_sink.
    This is why it recurs on ordinary use.

The obvious one-line fix (close the fd on the transition) was
UNSAFE because the fd was a bare shared atomic read by the accept
thread: the accept path did g_out_fd.load() then ioctl with no
synchronization (main.zig:238), so closing from the output thread
raced a recycled descriptor into an in-flight election ioctl. The
prior code only got away with the unsynchronized republish at
reopen because the deadlock meant the fd never churned; fixing the
deadlock unmasks that race. So this was a shared-descriptor
ownership problem across three roles (main seeds, output
republishes, accept reads-and-ioctls), not a one-liner.

RULING (operator, 2026-06-19): make the fd a single-owner type,
enforcing ownership by structure rather than by the comment that
AD-47 relied on. AD-fix under this entry, no new ADR (AD-43.1
precedent).

IMPLEMENTED (2026-06-19, compile-checked against Zig 0.16 and the
real compat module; committed; awaits bench):

  - New semasound/src/device_fd.zig: DeviceFd wraps the fd with a
    compat.sync.Mutex. The output thread owns lifecycle (release
    and adopt) and reads its hot write path via snapshot() with no
    lock (sound because it is the sole mutator). Every other thread
    touches the fd only through use(), which holds the lock for the
    call, so the fd cannot be closed and recycled mid-ioctl. The
    mutex is contended only between the rare election ioctl and the
    rare reconnect; the per-fragment write path never locks.

  - output.zig: real-state write error now calls ctx.fd.release()
    (close and mark absent, under the lock) before going to
    null_sink; reconnect calls ctx.fd.adopt(nfd). cur_fd tracks the
    owner-local value for the hot path. This is the actual fix: the
    device is released, output_stream_cdev_open clears via
    cdev_close, and the reconnect openWronly re-acquires it.

  - main.zig: g_out_fd and g_null_fd bare atomics become g_out_dev
    and g_null_dev DeviceFd. The accept path issues the election
    ioctl through g_out_dev.use(...), so it can never ioctl a
    closed-and-recycled fd. Startup adopts the fd; null target
    stays -1.

  - election.zig: applyElectionFd, an fd-first wrapper so
    DeviceFd.use() can prepend the fd.

Concurrency contract to check at ratification (documented in
device_fd.zig): release and adopt are owner-thread only; the owner
reads its hot path via snapshot() and is the sole mutator; every
cross-thread use goes through use() under the lock; ioctl-vs-ioctl
on a freshly adopted valid fd is serialized by the kernel cdev, not
by this type, which only prevents use-after-close.

RECORD (commit-message swap, cannot be reworded; pushed): the AD-50
and D1 commit messages landed crossed.
  - 06f68aa "AD-50: single-owner DeviceFd" actually contains the D1
    s6-log path change (/var/log/utf to /var/log/awase).
  - 64bcb9e "Point s6-log writers..." actually contains the AD-50
    single-owner DeviceFd change (device_fd.zig plus the
    output/main/election edits, verified byte-identical to the
    reviewed patch).
Both changes are correct and complete in tree; only the labels are
crossed.

RATIFIED (bench, 2026-06-20, operator-run ad50-ratify.sh): with the
AD-50 build installed (semasound rebuilt clean on the bench; the
container's sockaddr_un/openWronly errors were toolchain skew and did
not recur), the test forced the transition by kldunload audiofs under
the running writer, then kldload. The heartbeat captured the full
round trip: playing -> "degraded[default] ... device absent,
reconnecting" through the absence -> "device reopened on
/dev/audiofs0; output[default] resumed" -> playing, with
underflow_count flat at 0 before and after. Under the old leaked-fd /
EBUSY deadlock the degraded state persisted indefinitely; it now
recovers within the window. RESULT: PASS on all three signals
(resumed line seen, heartbeat back to playing, underflow flat). This
is the first bench-ratified close of the session's audio thread; idle
behavior separately showed zero underflow and an unbroken playing
heartbeat. Remaining optional hardening (not blocking close): the
gentler production trigger (client at a non-canonical rate tripping
the election SET_FORMAT) and a multi-cycle connect/disconnect soak,
both confirmatory of the same recovery already observed.

Note: ADR 0031 (audiofs state/event decoupling) is the independent
amplifier fix; it removes the path_dead_end storm that this unfed
stream drove through the F.3.d xrun path. AD-50 removes the trigger
(the unfed stream); 0031 removes the amplification. Both are
needed; neither subsumes the other. 0031 remains open.

### `[ ]` AD-44: inputfs kbdmux bridge has no consumer on PGSD post-AD-39  *(Open, Small, P3; surfaced 2026-05-27 evening during the "is drawfs replacing vt(4) and efifb?" audit; documentation-only disposition chosen, no code change)*

ADR 0019 (2026-05-09) implements an inputfs->kbdmux bridge so
`vt(4)` at `ttyv0..ttyvN` can receive keystrokes through
kbdmux when the only HID input source is inputfs's HID parser.
AD-39 (2026-05-13/14) compiled `vt`, `vt_vga`, `vt_efifb`,
`vt_vbefb`, `sc`, `vga`, `splash` out of the PGSD kernel
config. `kbdmux` itself is retained, but the bridge's
intended consumer (vt(4)) is no longer in the PGSD kernel.

So on PGSD kernels, the bridge publishes scancodes into a
kbdmux that has no reader. ADR 0019's "Post-AD-39
disposition" addendum (added 2026-05-27 evening) records the
detailed behaviour; the short summary is:

  - The bridge code path (`inputfs_kbd_intr_cb`,
    `inputfs_kbd_emit_at`, taskqueue enqueue, notify_task
    Giant acquire, kbdmux KBDIO_KEYINPUT callback) runs on
    every keystroke.
  - kbdmux holds the scancodes in the bridge's 1024-entry
    ring buffer until full, then silently drops further
    keys (`inputfs_kbd_put_key` line 441).
  - No `/dev/kbdmux0` reader pulls from the ring, because
    there is no `vt(4)` to do so.

#### Cost analysis

Memory: fixed ~4 KB per bridge softc instance (one ring per
bridge unit, typically 1 unit).

CPU: per-keystroke overhead, dominated by the Giant
acquire/release in `inputfs_kbd_notify_task` and the
kbdmux-layer callback work. At normal typing rates (a few
dozen keys/sec) this is invisible. At pathological rates
(keyboard stuck in repeat) it could matter but should still
not be visible against the rest of inputfs's HID-path cost.
**No bench measurement of this cost has been made;** the
above is an estimate from code reading.

Surface area: the bridge is code that runs on every keystroke
in spin-mutex context with no consumer, in a kernel where
panic is invisible on the framebuffer (per AD-39). A bug
inside the bridge path would be hard to diagnose. This is
the more interesting concern than CPU cost.

#### Options considered

A. **Document only (chosen).** Update ADR 0019 with the
   post-AD-39 disposition (done in commit landing this
   entry). Update AD-39's "what is retained" sentence to
   acknowledge the consumerless situation (done). File this
   AD-44 entry so the question stays visible. No code change.

B. **Default-off on PGSD.** Change the SYSCTL default for
   `hw.inputfs.kbdmux_bridge` from 1 to 0. Bridge becomes
   opt-in. Anyone running `inputfs.ko` on a non-PGSD system
   that has `vt(4)` in the kernel would lose console-login
   keystrokes silently until they set the sysctl back to 1.
   Not chosen: the sysctl default is compile-time, not
   runtime-conditional on "is vt(4) present?", so the
   change affects everyone using the same `inputfs.ko`
   regardless of kernel.

C. **Compile-out on PGSD.** Build-time gate
   (`INPUTFS_KBDMUX_BRIDGE`) that the PGSD kernel config
   omits. Zero surface area on PGSD; non-PGSD systems keep
   the bridge. Most invasive: source-level `#ifdef`s and a
   maintenance burden where `inputfs.ko` behaves differently
   on PGSD vs other systems at the binary level. Not chosen:
   the cost-of-doing-nothing is small enough that the
   compile-out work is premature.

#### Disposition

Option A (document only). Conservative choice given the audit
context ("better track our changes so we do not go off-course"):
making a code change based on the surface-area suspicion
without bench evidence is the same class of mistake as the
ADR 0002 misadventure two days earlier, where direction
preceded fact-finding. AD-44 records the question so it stays
visible, but does not act on it without observed harm.

#### What would trigger revisiting

Any of the following moves AD-44 from "document only" toward
Option B or Option C:

  - A kernel panic backtrace shows the bridge code path
    (`inputfs_kbd_intr_cb`, `inputfs_kbd_emit_at`, or
    `inputfs_kbd_notify_task`) as the panic site or
    immediate caller.

  - A bench measurement shows the per-keystroke bridge cost
    is non-negligible (e.g. measurable in `pmcstat` or
    showing up in lldb sampling on the inputfs interrupt
    path).

  - A new non-vt(4) consumer of kbdmux is identified or
    proposed (e.g. a hypothetical recovery shell). In that
    case the bridge's purpose continues post-AD-39 and the
    disposition becomes "keep enabled," not just "document."

  - The complement: a verifiable absence of any plausible
    future consumer. In that case Option C (compile-out)
    becomes the cleanest path.

#### References

  - `inputfs/docs/adr/0019-kbdmux-bridge.md`, Status section
    "Post-AD-39 disposition" addendum (the authoritative
    description of the bridge's post-AD-39 environment).
  - `inputfs/sys/dev/inputfs/inputfs_kbdmux.c:139-143` (the
    `hw.inputfs.kbdmux_bridge` SYSCTL declaration, default 1).
  - `inputfs/sys/dev/inputfs/inputfs_kbdmux.c:429-449`
    (`inputfs_kbd_put_key`, the silent-drop-on-full
    behaviour).
  - `inputfs/sys/dev/inputfs/inputfs_kbdmux.c:673-685`
    (`inputfs_kbd_notify_task`, the Giant-acquire
    per-keystroke).
  - BACKLOG.md AD-39 (line 9929), the supersedure of AD-10
    via kernel compile-out; the entry's "kbdmux is retained"
    sentence now forward-references this AD-44.
  - BACKLOG.md AD-10.5 (line 3466), the original closure of
    the keystroke-handover sub-stage; closed independently
    of AD-39's framebuffer-ownership change and is not
    affected by this entry.


### `[ ]` AD-45: whole-of-project supervision evaluation  *(Deferred by design; opened 2026-06-05 as the tracking entry for ADR 0028 Decision 1's deferral)*

ADR 0028 Decision 1 deferred a deliberate whole-of-project
evaluation of the supervision architecture (s6 vs rc(8)/daemon(8)
and everything in between) until field experience accumulates;
ADR 0030 Decision 6 assigned svscan.log rotation here. This entry
exists so both have an owning item and neither silently vanishes.

Scope when opened for real: the rc(8)/daemon(8) analysis recorded
in ADR 0028 as considered-and-deferred; the AD-20 architecture's
field record (flap protection, the catch-all svscan.log, the
takeover protocol's friction); log hygiene including svscan.log
rotation (the file grows unrotated and reached 8 MB during the
first week of supervised operation); and whether the per-service
s6-log retention defaults fit observed volume. Not before field
experience justifies it; the deferral is the decision, this entry
is only its bookmark.

### `[x]` AD-54: protocol_constants.json / generated-output reconciliation  *(Closed 2026-06-14, operator-ratified; shared/ generation-contract repair)*

The repository source-of-truth and generated artifacts diverged:
`gen_constants.py --validate` failed on the committed tree because
`shared/protocol_constants.json` no longer matched the committed generated
files (`semadraw/src/ipc/protocol.zig`, `semadraw/src/sdcs.zig`,
`drawfs/sys/dev/drawfs/drawfs_proto.h`). The JSON had been frozen at the
post-rename baseline while the SDCS paint/clip opcodes and the D-10
session-lock messages were ratified and landed in committed code without
the JSON being updated alongside. Running the generator on the drifted
tree would have stripped ten shipped constants.

Reconciliation restored consistency by updating `protocol_constants.json`
to reflect the ratified protocol already present in committed code: the
six SDCS opcodes (`SET_SOURCE_NONE`/`LINEAR_GRADIENT`/`RADIAL_GRADIENT`/
`PATTERN` 0x0008 through 0x000B, `SET_CLIP_PATH` 0x000C, `FILL_PATH`
0x0019), the four session-lock messages (0x0035/0x0036 requests,
0x9004/0x9005 events), and a narrowed `idle_query` reserved-range note.
Regeneration is now idempotent: the generated files are byte-identical to
committed output.

Closure criterion: `gen_constants.py --validate` now passes on a clean
tree. Surfaced 2026-06-14 while adding the D-7 `set_focus`/`focus_changed`
constants. Recurrence prevention is tracked separately as AD-55.

### `[ ]` AD-55: generator integrity enforcement  *(Open 2026-06-14, Small, P2; prevents recurrence of AD-54-class drift)*

Wire `gen_constants.py --validate` into CI, pre-merge checks, or
`tests/run.sh` so protocol-definition drift between
`shared/protocol_constants.json` and the generated artifacts cannot
silently accumulate again. AD-54 repaired the current drift; this item is
the standing guard against the same class recurring. The failure mode
AD-54 encountered (drift invisible until someone regenerates months later)
is exactly what an automated `--validate` gate catches at the point of
introduction. Placement is the open design question: `tests/run.sh` is the
reliable backstop since it always runs at bench time; a pre-commit hook
would catch it earlier but is bypassable. No ADR required (enforcement
mechanism, not a protocol change).

### `[ ]` AD-60: audiofs path_dead_end event repetition floods the events ring  *(Open 2026-07-07, Small, P3; disposed here from pgsd-loader L0 campaign finding F2)*

Observed on bare-metal-test-bench during the L0 boot campaign,
present before and independent of the loader work: the
path_dead_end events for nids 0xc/0xd/0xe/0xf/0x12 repeat in
identical groups of five at roughly 21 ms intervals well after
attach completes (dmesg timestamps 12.398, 12.419, 12.441,
12.462, continuing), a cadence suggesting something in the
running stream path re-walks codec topology and re-emits the
same findings every cycle, flooding the events ring with
duplicates. To investigate: which loop emits them (the 21 ms
cadence is suspiciously close to the stream interrupt period),
whether dead-end findings should be emitted once at discovery
rather than per walk, and whether the ring's useful capacity is
materially reduced on long uptimes.

### `[ ]` AD-61: TxFAT32, transactional publication profile over FAT32  *(Open 2026-07-08, Medium, P2; extraction decision deferred pending L3a bench evidence)*

Operator-originated from the L0 campaign and project ADR 0001:
with designated tooling as sole writer (ADR 0001 Decision 1) and
firmware plus legacy systems as read-only FAT32 clients,
publication semantics become a writer protocol over unmodified
FAT32 rather than a filesystem change. Core design as discussed:
slotted artifacts written under non-live names (crash leaves
discardable orphans, never damaged live state); commit via a
preallocated fixed-size contiguous dual-copy selector file whose
switch is a single data-sector overwrite touching no directory or
FAT metadata (sequence number plus CRC, reader takes highest
valid); ordering contract, slot data flushed before selector
write, selector flushed before success reported; garbage
collection of unreferenced slots; intent journal as an optional
observability extension, not required for deterministic recovery.
Self-hosting boundary: firmware-read artifacts (the loader
itself) use NVRAM boot entries as their selector, the L0
dual-entry design being the same commit pattern on a different
substrate. Name avoids the historical Microsoft TFAT. Disposition
plan: specified as a self-contained, parameterized section of
BOOT-ARTIFACT-STORE at L3a (the sole current consumer);
standalone extraction evaluated only after an L3a bench campaign
has exercised publications, power events, and GC against it.
