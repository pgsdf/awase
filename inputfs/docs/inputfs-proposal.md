# inputfs — Native Input Substrate Proposal

Status: Accepted, 2026-04-23. Stages A, B, C, D landed
on PGSD-bare-metal. Stage E (cutover, evdev removal) is the
next intentional act and is tracked as AD-2a in `BACKLOG.md`.

## Summary

UTF will replace its dependence on FreeBSD's evdev compatibility layer with
a native kernel input substrate, `inputfs`, modelled after `drawfs`. Input
becomes a first-class kernel service: device enumeration, HID report
parsing, coordinate normalisation, focus routing, and audio-clock-stamped
event publication all happen in the kernel. Userspace consumers read from
a shared-memory publication layer analogous to `semaaud`'s clock region,
and receive routed events through the same per-session event queue that
`drawfs` already uses for keys.

This document argues that evdev's shape is incompatible with UTF's
architectural commitments, describes the native substrate that replaces
it, and sketches a migration path that keeps UTF operational throughout.
It does not specify ioctl numbers, struct layouts, or a schedule. Those
belong in follow-on ADRs.

This proposal is the first named application of the discipline stated
in `docs/UTF_ARCHITECTURAL_DISCIPLINE.md`: **UTF depends only on code
written with UTF's guarantees in mind**. evdev is an external
dependency whose authors were not thinking about UTF's determinism or
stability commitments; it sits inside UTF's guarantee path; therefore
it is replaced. The discipline document provides the broader context
for why this work is being done. This proposal describes the specific
shape of the replacement.

## Why evdev is the wrong model for UTF

The rest of UTF is built on a consistent premise: the kernel owns the
authoritative state, userspace daemons publish derived views, and the
compositor is the single arbiter of what reaches clients. `drawfs` owns
the framebuffer and surface registry. `semaaud` owns the audio clock.
`chronofs` provides the clock bus. evdev fits none of these patterns.
It is Linux's input ABI, emulated on FreeBSD through a compatibility
shim, and its assumptions were formed in an era before compositors owned
display geometry and before audio-clock time was a concept.

Seven concrete mismatches show up in the current code.

**No canonical coordinate origin.** evdev reports `REL_X` and `REL_Y`
deltas with no defined starting position. Every consumer invents its
own seeding — in UTF's case, `cursor_x` and `cursor_y` in semainputd are
initialised to `(0, 0)` and drift wherever the user's mouse motion takes
them, producing the observed `y=-568` during mouse testing. There is no
sensible point at which a relative-delta model can produce correct
screen-absolute coordinates without external knowledge of display
geometry, which evdev itself does not carry.

**Relative-delta-only pointer events despite UTF owning the display.**
The kernel already knows the framebuffer dimensions — efifb exposes them
as `3840x2160` at module load. An input substrate that lives alongside
drawfs can normalise pointer coordinates against display geometry at
source. evdev, being device-centric, cannot.

**Device-centric events versus semantic events.** `REL_X`, `REL_Y`,
`BTN_LEFT`, `KEY_A` are not what compositor clients want. They want
"pointer moved to (x, y), left button is pressed, text caret advanced to
cell (col, row)." Today semainputd carries a non-trivial
aggregator/classifier layer whose sole purpose is reconstructing
semantic state from evdev's raw HID-ish reporting. That layer is
complexity paid for working around evdev's abstraction level, not for
any feature UTF would otherwise want.

**No multiplexing primitive.** evdev exposes one file descriptor per
input device (`/dev/input/event0` through `event8` in the current
testbed). semainputd opens all nine at startup, grabs each with
`EVIOCGRAB`, and spawns a reader thread per device. There is no
`input_epoll`, no unified event stream. A UTF-native substrate can
present a single fd or shared-memory region carrying all devices'
events, eliminating nine reader threads.

**FreeBSD compatibility-layer semantics.** On FreeBSD, evdev is provided
by the `evdev` kernel module as a compatibility shim atop the native
`sysmouse`/`kbdmux` infrastructure. Every event traverses an emulation
boundary that was written to satisfy Linux porters, not to be a
foundation for new designs. Bugs in the shim surface as UTF bugs;
feature gaps in the shim (`EV_MSC`, `EV_SND`, multi-touch subtleties)
leak through to UTF.

**No clock integration.** evdev timestamps events with wall-clock time
(`struct input_event.time`, a `struct timeval`). UTF's unified event
schema uses audio-sample positions (`ts_audio_samples`) as the primary
time axis, with wall-clock as a secondary field. Every consumer of
evdev events in UTF must translate or accept timing drift. A native
substrate timestamps with audio-sample position at source.

**Capabilities taxonomy predates modern input classes.** evdev's bit
table (`EV_KEY`, `EV_REL`, `EV_ABS`, `EV_MSC`, `EV_LED`, `EV_SND`,
`EV_REP`, `EV_FF`) reflects keyboards, mice, and joysticks as they
existed in Linux 2.4. Multi-touch support was bolted on later. Pen,
stylus, gesture, spatial, and chord-keyboard input are reconstructed by
convention. UTF will want first-class support for touch and pen
eventually, and a semantic-role taxonomy — pointer, keyboard, touch,
pen, tablet, gesture — fits that future where evdev's bitmap does not.

## What the UTF-native model looks like

`inputfs` is a kernel module, a sibling of `drawfs`, owning input the way
`drawfs` owns graphics. It is designed around the same principles as the
rest of UTF: protocol-first, explicit resource lifetimes, clear separation
of mechanism and policy, clock-integrated, hardware-agnostic baseline.

### Kernel-side device ownership

`inputfs` enumerates input devices through the native FreeBSD device
tree — `/dev/ukbd*`, `/dev/ums*`, `/dev/uhid*`, `/dev/atkbd0`,
`/dev/psm0` — and parses their reports directly. For USB HID devices
this means implementing a subset of HID report parsing sufficient for
the device classes UTF cares about. For legacy devices it means
reading the PS/2 or AT protocols the FreeBSD drivers already expose.
No evdev layer in between.

Device enumeration, connection, and disconnection are observed by the
module and published through the same event stream as input events
themselves. Hotplug becomes a first-class event type rather than a
scanning exercise.

### Shared-memory publication

Following the `semaaud` clock pattern, `inputfs` publishes a
shared-memory region at `/var/run/sema/input` containing:

* **Current pointer state** — logical_id, screen-absolute x/y, button
  bitmask, last-update audio sample position.
* **Current keyboard state** — logical_id per attached keyboard,
  modifier bitmask, last-update audio sample position.
* **Recent event ring** — fixed-size circular buffer of recent input
  events, audio-clock-stamped, for consumers that want history rather
  than latest-state.
* **Device inventory** — current list of attached input devices with
  their semantic roles.

This region is readable by any process that has read access; it does not
require ioctls, subscription, or per-event IPC. A gesture recogniser, a
screen-recording tool, or an accessibility aid can consume input state
without imposing latency on the primary event path.

This is the same trade-off `semaaud` made for its clock: state is cheap
to publish, cheap to read, and does not require every consumer to
open a connection to the producer.

### Compositor-driven routing

Event delivery to specific clients stays in the kernel, following the
pattern `drawfs` already uses for injected `EVT_KEY` frames. The
compositor publishes a "focus" surface id through `inputfs`; the kernel
routes keyboard events to the session that owns the focused surface,
and pointer events to the session that owns the surface under the
cursor. Both use the same per-session event queue that `drawfs` already
exposes through `/dev/draw` reads.

The userspace injector (`semainputd`'s current `DRAWFSGIOC_INJECT_INPUT`
path) disappears. Events flow kernel → compositor's drawfs session
natively. The injector exists today only because evdev events arrive
in userspace and have to be re-entered into the kernel to reach the
compositor. With `inputfs`, they never leave.

### Audio-clock timestamps

Every event in the recent-event ring and every state update in the
published region carries `ts_audio_samples`, read from `semaaud`'s
published clock at the moment of HID report parsing. Wall-clock time
is available as a secondary field for debug but not used for ordering.
UTF's existing event-log convention — audio-sample position as the
primary time axis — extends cleanly into input.

### Semantic device roles

`inputfs` classifies each attached device into a role at enumeration
time: `pointer`, `keyboard`, `touch`, `pen`, `gamepad`, `unknown`.
Role assignment is a first-class kernel concern, not a userspace
reconstruction from capability bitmaps. The role determines which
event variants the device produces and which state fields it updates
in the published region.

Devices that belong to multiple roles (a gaming mouse with extra keys,
a tablet with an integrated keyboard) are enumerated as multiple
logical devices. The kernel maintains a stable mapping from physical
device to one-or-more logical devices.

### Coordinate normalisation at source

Pointer events carry screen-absolute pixel coordinates from the first
event. The kernel knows display geometry via `drawfs`'s efifb
integration, and on startup or display-change it seeds the pointer
position to the display centre. Relative motion events update the
position with clamping to the display bounds. Absolute-pointing
devices (touchscreens, tablets) publish their native coordinates after
normalisation.

The compositor no longer needs to translate. Its `forwardMouseEvents`
path becomes a pass-through of screen coordinates into
`MouseEventMsg`, and clients perform their own surface-local
translation using the surface origin they already know.

## Migration path

This is the hard part. The plan is to keep UTF operational at every
stage; no stage breaks what the previous stage left working. Five
stages, each a shippable milestone. There is no evdev fallback stage
beyond Stage E's cutover; see Stage E for the rationale.

### Stage A — Design

This document plus supporting ADRs. No code.

The ADRs that need to land in this stage are:

1. `inputfs` kernel module charter — scope, device classes, naming.
2. Shared-memory region layout and semantics.
3. Compositor focus publication interface.
4. Semantic role taxonomy and role-to-event-variant mapping.

### Stage B — Module skeleton

`inputfs.ko` builds and loads. It enumerates input devices through
the native FreeBSD device tree and parses HID reports for two device
classes only: USB keyboards and USB mice. No routing, no coordinate
normalisation, no state publication yet — just raw event reception
and kernel-log-level visibility.

Purpose: prove the device enumeration and parsing path. Everything
still flows through evdev for production use. `inputfs` is an
observational module.

### Stage C — State publication

`/var/run/sema/input` appears. The shared-memory region exposes current
pointer state (x, y, buttons), current keyboard state (modifier
bitmask), and the recent-event ring. A CLI tool, `inputdump`,
parallels `chronofs`'s `chrono_dump` and displays live state.

Purpose: prove the publication model. semainputd is unchanged.
evdev still drives production input. `inputfs` now has a user-visible
output but no consumers yet.

### Stage D — Coordinate normalisation and routing

`inputfs` integrates with `drawfs`: it learns display geometry on
module load, seeds pointer position to the display centre, and
translates device motion into screen-absolute coordinates. It also
implements focus-driven routing: a new `DRAWFSGIOC_SET_FOCUS`
interface lets the compositor publish which surface should receive
input, and `inputfs` enqueues events into that session's event queue.

Purpose: reach functional parity with the current evdev+semainputd+
injector pipeline, but natively. Both paths are live at this point,
controlled by a kernel tunable (`hw.inputfs.enable=0|1`). Production
input can be switched between them without reboot.

### Stage E — Cutover and evdev removal

semadrawd reads from the `inputfs` path instead of the evdev-injected
path. `forwardMouseEvents` passes coordinates through without
translation in the compositor-side shim sense (the shim is no longer
needed; inputfs has normalised coordinates at source).

semainputd's evdev reader and the `drawfs_inject.zig` adapter are
removed. The `hw.inputfs.enable=0` tunable from Stage D is removed.
semainputd either shrinks to a pure classifier or goes away entirely;
this is a Stage E design question tracked as AD-2 in `BACKLOG.md`.

Purpose: UTF runs on inputfs in production with no evdev fallback.
This is a deliberate commitment, not an oversight. Keeping evdev as
a standby would keep it in the guarantee path — a bug or change in
evdev could affect UTF whenever the fallback activated or whenever
its presence changed timing. The discipline in
`docs/UTF_ARCHITECTURAL_DISCIPLINE.md` says external code stays out
of the guarantee path; that applies to fallbacks too. Either inputfs
works or UTF does not run on this code path.

Stages A through D must therefore land with enough confidence that
cutover without a safety net is reasonable. The staged delivery and
the coexistence period in Stage D (both paths live, tunable-switched)
are where that confidence is built.

### Interim status: the mouse coordinate bug

The mouse coordinate translation work scoped as D-6 in `BACKLOG.md`
becomes moot under this plan. The bug ("clients receive
device-accumulated coordinates where they expect surface-local
pixels") is a symptom of evdev's missing origin; `inputfs` fixes it
at source in Stage D. Between now and Stage D's completion,
mouse events flow end-to-end but coordinates land in wrong cells.
This is a non-crash bug and is explicitly accepted as a transient
state during the migration.

D-6 was closed as superseded when this document was accepted;
see D-6's entry in `BACKLOG.md` and `semadraw/docs/adr/0003-mouse-coordinate-translation.md`
for the historical record of the narrower fix that was considered.
The broader inputfs work this document proposes is tracked as AD-1
in the Architectural Discipline section of `BACKLOG.md`.

## Known unknowns

Decisions deferred to future ADRs or learned through implementation.

**HID parsing scope.** How much of the USB HID specification does
`inputfs` implement? A minimal subset sufficient for keyboards, mice,
and touchscreens is the Stage B target. Pen and tablet come later.
Gamepad support is deferred indefinitely. Vendor-specific report
formats are out of scope unless upstream FreeBSD drivers already
normalise them.

**Hotplug semantics.** Device arrival and removal produce events in
the ring buffer and update the device inventory. What the compositor
and focused client do with those events is policy, not mechanism.
The module publishes; clients react.

**Multi-seat.** UTF may eventually want to support multiple concurrent
user sessions on the same hardware. `inputfs` does not address this
in its first design. Multi-seat is a separable concern that could
layer on top of `inputfs` through per-seat device filtering and
per-seat published state regions.

**Accessibility.** Screen readers, switch access, and other assistive
technologies often need to synthesise input events (the X11 `xtest`
and Linux `uinput` interfaces). `inputfs` will need a synthesis path
eventually. The shape of that path — a separate ioctl, a write-side
of the event ring, a privileged-only channel — is an open question.

**Remote input.** RDP-style remote operation would feed a virtual
`inputfs` device rather than a physical one. The abstraction should
support this, but the first design does not explicitly model virtual
devices. Stage F or later.

**Non-x86-64 platforms.** FreeBSD on arm64 and riscv64 have different
HID entry points (ACPI tables, device-tree bindings). `inputfs`'s
enumeration layer needs to handle these; the parsing layer is
architecture-independent.

**Clock behaviour during semaaud outage.** `inputfs` stamps events
with audio-clock position read from `/var/run/sema/clock`. What
happens when `semaaud` is not running or its clock region is
unavailable? The existing UTF convention — emit events with
`ts_audio_samples: null` and wall-clock only — carries over.

## What this document is not

Not an implementation schedule. No timelines, no sprint mapping.
Stage sizes will emerge from the ADRs.

Not a deprecation notice for evdev. evdev remains functional through
Stage E as a tested fallback. Stage F removes UTF's dependency on it;
the kernel module itself is unaffected.

Not a proposal for specific ioctl numbers, struct layouts, or syscall
interfaces. Those come in follow-on ADRs, one per major interface.

Not a commitment to the stage sequence as stated. Stages may merge,
split, or reorder as implementation reveals constraints. The commitment
is to the destination (UTF owns input natively) and to the principle
(no stage breaks a working system).

## Related work

`drawfs/docs/DESIGN.md` — the template this proposal follows. `inputfs`
is `drawfs`'s sibling in the same way `semaaud` is `semadrawd`'s
sibling at the audio layer.

`semaaud` shared-memory clock publication — the reference
implementation of the publication pattern `inputfs` will adopt.

`BACKLOG.md` D-6 — the mouse coordinate translation work item that
this proposal supersedes. D-6 will be closed as superseded when this
document is accepted and referenced from a revised ADR-0003.

ADR-0002 (reference renderer) — an example of the ADR depth used for
substrate decisions in UTF. The follow-on ADRs for `inputfs` will
match that level of detail.
