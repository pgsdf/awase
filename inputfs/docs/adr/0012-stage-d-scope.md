# 0012 Stage D scope and design (focus routing, coordinate transform)

## Status

Proposed.

This ADR records the architectural decisions made during Stage D
scoping, after Stage C closed out on PGSD-bare-metal. It does not
specify implementation; per-decision implementation lives in
sub-stage commits as the work proceeds. It does specify the wire
format additions that downstream specs (`shared/INPUT_STATE.md`,
`shared/INPUT_EVENTS.md`) will encode and that
`shared/src/input.zig` will expose.

**Update (2026-04-29):** All eight sub-stages (D.0a, D.0b,
D.1, D.2, D.3, D.4, D.5, D.6) have landed and verified on
PGSD-bare-metal. Stage D is complete. Per-sub-stage status
is recorded in §7 below.

## Context

Stage C published the state region and event ring under
`/var/run/sema/input/` per the byte layouts in
`shared/INPUT_STATE.md`, `shared/INPUT_EVENTS.md`, and
`shared/INPUT_FOCUS.md`. The state region carries pointer
position in raw device space (accumulated boot-protocol mouse
deltas) because inputfs has no transform machinery yet. The event
ring carries pointer.motion, pointer.button_down/_up, and
device_lifecycle.attach/detach events. Routing is not yet applied:
the focus region exists and `FocusReader` is implemented in
`shared/src/input.zig`, but inputfs itself does not consume it.

Stage D fills in the remaining substrate work needed for the
proposal's Stage E cutover (replacing evdev as the production
input path):

- Coordinate transform: pointer position in compositor-space
  pixels rather than raw accumulated deltas.
- Focus-driven routing: events stamped with the destination
  session id, computed from the focus region's keyboard_focus,
  pointer_grab, and surface_map fields.
- Event diversity: descriptor-driven keyboard events (Stage C
  emits only pointer events plus lifecycle events, because
  keyboard events require descriptor-driven parsing that was
  deferred during C.3).
- Coexistence tunable: `hw.inputfs.enable` gates publication so
  the legacy evdev + semainputd + drawfs_inject path remains
  switchable until Stage E cutover.

ADR 0001 (charter) commits inputfs to owning the full pipeline
including focus-routed delivery. ADR 0002 (shared-memory regions)
deferred the transform mechanism explicitly to Stage D. ADR 0003
(focus publication) specified the compositor-to-inputfs interface
that inputfs now implements the kernel side of. The proposal's
Stage D section sketched the work but predated the focus region
design (referencing a `DRAWFSGIOC_SET_FOCUS` ioctl that was
superseded by the shared-memory region in ADR 0003); this ADR is
the up-to-date scope statement.

## Decision

### 1. Coordinate transform mechanism

inputfs learns display geometry from `drawfs` at module load via
sysctl. No fourth shared-memory region is introduced. Per-device
transform fields are deferred until absolute-coordinate devices
(touchscreens, tablets) come into scope, post Stage D.

drawfs publishes display geometry under `hw.drawfs.efifb.*`
sysctl nodes (width, height, pitch, format) using standard
FreeBSD sysctl machinery. inputfs reads them at load via
`kernel_sysctlbyname` (or equivalent), with a conservative
default (1024x768 or 1920x1080 to be settled in implementation)
if the sysctls are absent so inputfs remains loadable standalone
during bring-up and testing.

Direct cross-module symbol references and `MODULE_DEPEND`
relationships are explicitly avoided: they introduce load-order
constraints and link-time coupling that make either module
brittle to internal changes in the other. Sysctl is FreeBSD-
idiomatic for read-only kernel-to-kernel exposure of static
geometry, debuggable from userspace via `sysctl(8)`, and
requires no new shared-memory region.

If absolute-coordinate devices later need per-device transform
fields, that work is a separate sub-item: it requires reserved
space in the device slot (currently fully consumed by
`lighting_caps` from offset 104 to 160) and would either bump
INPUT_STATE_VERSION or repurpose part of the lighting reserve.
Stage D does not block on that decision.

For Stage D, the transform applied to relative pointer motion is:

- Accumulate boot-protocol-style or descriptor-driven dx/dy into
  a global pointer position.
- Clamp to display bounds learned from drawfs.
- Optionally apply a global acceleration curve (deferred unless
  needed for parity with semainputd's existing smoothing).
- Publish the resulting `(pointer_x, pointer_y)` in compositor
  pixel space to the state region.

Pointer position is seeded to display centre on first transform
activation, matching the proposal's Stage D wording.

### 2. Focus routing logic placement

Routing logic lives fully in inputfs (kernel-side). The
compositor's responsibility ends at writing the focus region via
`FocusWriter` (already implemented in `shared/src/input.zig`).
inputfs implements the kernel-side equivalent of `FocusReader`
in C, snapshots the focus region under the seqlock retry
protocol, and applies routing rules per ADR 0003:

- Keyboard events: deliver to `keyboard_focus` if non-zero.
- Pointer events: deliver to `pointer_grab` if non-zero;
  otherwise look up `surfaceUnderCursor(pointer_x, pointer_y)`
  using the surface_map; otherwise no session.
- Pointer enter / leave: synthesised by inputfs when the
  surface-under-cursor changes between successive pointer
  events, per ADR 0003 §Decision 5.

This rejects two alternatives considered during scoping:

- *Userspace shim path* (let userspace consumers apply routing):
  adds latency, defeats the native-substrate goal of ADR 0001,
  and pushes complexity into multiple consumers instead of one
  kernel implementation.
- *Split with the compositor via ioctl* (a `DRAWFSGIOC_SET_FOCUS`
  or equivalent): adds ioctl roundtrips, was the original
  proposal sketch's idea but was superseded by ADR 0003's
  shared-memory region.

The kernel-side `FocusReader` cannot link the Zig
`shared/src/input.zig` implementation. It is rewritten in C for
the kernel context, mirroring how C.2/C.3 rewrote
`StateWriter`/`EventRingWriter` from the Zig spec into kernel C.

### 3. Per-session event delivery

Events are delivered via the existing global event ring,
stamped with a destination `session_id` per event. Per-session
event rings are not introduced.

`session_id` is placed in the per-event-type payload (the 32-byte
payload field of each event slot), not in the unified event
header. This avoids a wire-format break: the existing 64-byte
event slot header is fully consumed (8 seq + 8 ts_ordering + 8
ts_sync + 2 device_slot + 1 source_role + 1 event_type + 4 flags
= 32, plus 32 payload = 64), so a new header field would require
a v2 bump and break Stage C consumers.

Per-event-type payloads have slack:

- pointer.motion: x(4) + y(4) + dx(4) + dy(4) + buttons(4) = 20
  bytes. 12 bytes spare for `session_id` plus future fields.
- pointer.button_down/_up: x(4) + y(4) + button(4) + buttons(4)
  = 16 bytes. 16 bytes spare.
- device_lifecycle.attach: roles(4) = 4 bytes. 28 bytes spare.
- device_lifecycle.detach: empty. 32 bytes spare.
- keyboard events (added in Stage D): scratch design needs
  `session_id` plus key_code, modifier_mask, and any
  per-event-type fields. Layout decided in
  `shared/INPUT_EVENTS.md` updates, with `session_id` placement
  guaranteed.

Consumers filter by `session_id` after decoding the per-type
payload. Per-session rings remain a future optimisation if
contention or isolation requirements emerge.

### 4. Coordinate semantics signaling

A `transform_active` byte is added to the state region header at
a previously-reserved offset. Its semantics:

- `0`: pointer_x and pointer_y are in raw device space
  (accumulated boot-protocol or descriptor-driven deltas), as
  Stage C published. Stage C consumers see this value.
- `1`: pointer_x and pointer_y are in compositor pixel space,
  as Stage D publishes.

The byte is read once per state snapshot. Existing Stage C
consumers (just `inputdump` currently) need no code change to
function; consumers that interpret pointer_x/y in
compositor-space terms must check `transform_active == 1` first
or risk misinterpreting raw-space coordinates as pixel
coordinates.

The state region's spec (`shared/INPUT_STATE.md`) documents the
field, the offset (chosen from the existing reserved byte ranges
in the header), and the semantics for both values.

### 5. Tunable scope and lifecycle

`hw.inputfs.enable` is a sysctl with two states:

- `1` (default): inputfs publishes state and events normally.
- `0`: inputfs is fully inert for publication. The state region
  has `state_valid = 0`, the event ring has `events_valid = 0`,
  and no updates flow to either. The kernel module remains
  loaded; the legacy evdev + semainputd + drawfs_inject path
  remains the production input path.

State transitions:

- `0 -> 1` (going live): inputfs publishes a fresh state
  snapshot reflecting the current device inventory and pointer
  position, resets the event ring (writer_seq = 0,
  earliest_seq = 1), sets `state_valid = 1` and
  `events_valid = 1`. Userspace consumers see fresh, valid
  publication regions.
- `1 -> 0` (going inert): inputfs sets `state_valid = 0` and
  `events_valid = 0` first, so consumers see "this region is
  no longer authoritative" before any subsequent updates would
  diverge. The kthread continues to drain pending writes (so
  the file content reaches a consistent stopped state) and
  then ceases publication.

Mid-stage Stage D bring-up runs with `hw.inputfs.enable = 0` so
the legacy path stays in production while inputfs is exercised
and verified. The default flips to `1` only when Stage D's
verification protocol passes end-to-end.

This tunable is removed in Stage E (cutover), per the proposal:
"the `hw.inputfs.enable=0` tunable from Stage D is removed."

### 6. Descriptor-driven event generation scope

Stage D's descriptor-driven event work is scoped narrowly:

- **D.0a (descriptor-driven pointer)**: replace boot-protocol
  parsing with `hid_locate`-based extraction at attach and
  `hid_get_data` calls at interrupt time. Adds report-ID
  dispatch for devices with multiple top-level collections.
  Adds scroll-wheel event type if `HUG_WHEEL` is present.
- **D.0b (descriptor-driven keyboard)**: emit
  `keyboard.key_down` / `keyboard.key_up` events from
  descriptor-driven parsing of the modifier byte and the
  keys-held array under HUP_KEYBOARD. Tracks held keys in the
  softc to compute transitions. Modifier state is carried in
  the per-event `modifiers` payload field, not emitted as
  separate events: the spec at `shared/INPUT_EVENTS.md`
  already specifies this layout (Stage A artifact). Pure
  modifier-only presses (e.g. Shift alone) are emitted as
  ordinary `key_down` / `key_up` events whose `hid_usage`
  identifies the modifier key; consumers detect modifier
  state changes by tracking the `modifiers` field across
  successive keyboard events.

Touch and pen are explicitly out of scope for Stage D. Touch
descriptors use HUP_DIGITIZERS with multi-contact sub-collections
that are non-trivial to parse correctly; pen has fewer fields
but similar shape. Both are tracked as a separate AD-1 sub-item
post Stage D. The HAILUCK touchpad on the bench currently
exposes a pointer TLC that uses boot-protocol-equivalent layout,
so its mouse-like behaviour continues working through D.0a; its
multi-touch capabilities are simply not surfaced.

The kernel uses FreeBSD's existing HID parser primitives
(`hid_start_parse`, `hid_get_item`, `hid_locate`, `hid_get_data`,
`hid_report_size`) via `<dev/hid/hid.h>`. inputfs does not write
its own descriptor parser. At attach, inputfs caches one
`hid_location` per usage of interest in the softc, inline (not
heap-allocated), so cleanup is automatic at detach.

Three implementation conventions are fixed:

- **Inline `hid_location` cache**: `hid_location` structs live
  in the softc, not heap-allocated. Lifecycle is the softc's
  lifecycle; no separate free needed.
- **Modifier state carried per event, not as separate events**:
  the existing `shared/INPUT_EVENTS.md` keyboard payload layout
  (Stage A artifact) carries `modifiers` as a u32 bitmask in
  every keyboard event. inputfs follows that spec: there are no
  `keyboard.modifier_down` / `keyboard.modifier_up` event types.
  Pure modifier-only presses become ordinary `key_down` /
  `key_up` events whose `hid_usage` identifies the modifier
  key; consumers detect modifier state changes by tracking the
  `modifiers` field across successive keyboard events. This
  diverges from evdev's per-keycode model deliberately: inputfs
  events can carry both the keycode and the modifier mask
  atomically, which evdev cannot.
- **Auto-repeat is not synthesised by inputfs**: hardware
  keyboards don't generate repeat at the HID level, and the
  decision of repeat policy belongs in userspace (or in the
  consuming session's library). inputfs publishes raw key_down
  / key_up; consumers add repeat policy.

### 7. Stage D sub-stage breakdown

Eight sub-stages, each landed and verified independently before
the next starts:

- **D.0a** *(landed)*: descriptor-driven pointer events (replaces
  boot-protocol parser; adds report-ID dispatch; adds scroll
  wheel). Inputfs's pointer location cache is populated at attach
  via `hid_locate` for X, Y, wheel, and per-button bits, then
  consulted in the interrupt handler to extract real 16-bit
  precision deltas and per-button state on every report.
- **D.0b** *(landed)*: descriptor-driven keyboard events
  (`keyboard.key_down` and `keyboard.key_up` with `hid_usage`
  payload). Modifier handling folds into the per-event
  `modifiers` field as documented in `shared/INPUT_EVENTS.md`;
  there are no separate `modifier_down` / `modifier_up` event
  types. Set-based diff against per-device previous-state
  buffers; releases-before-presses ordering within each report.
- **D.1** *(landed)*: kernel-side `FocusReader` equivalent in C.
  Allocates a 5184-byte cached buffer; the kthread refreshes it
  via `vn_rdwr` every ~100 ms (bounded `msleep_spin` timeout);
  consumers call `inputfs_focus_snapshot` from interrupt context
  and read under spin lock. Seqlock retry is folded into the
  refresh-then-validate cycle rather than a snapshot-side loop.
- **D.2** *(landed)*: drawfs geometry sysctl publish (drawfs
  side: `hw.drawfs.efifb.{width,height,stride,bpp}` via
  `SYSCTL_PROC` + accessor functions) and inputfs reads at
  module load via `kernel_sysctlbyname` with fallback to
  `1024x768x32` when sysctls are absent.
- **D.3** *(landed; amended 2026-05-06)*: coordinate transform
  applied to pointer state. When display geometry is known
  (`inputfs_geom_known == 1` from D.2), the pointer accumulator
  in `inputfs_state_update_pointer` is clamped to
  `[0, geom_width-1] × [0, geom_height-1]` and the state
  header's `transform_active` byte at offset 48 is set to 1.
  The pointer is seeded at the display centre at module load.
  When geometry is not known, `transform_active` stays 0 and
  the accumulator runs unclamped (Stage C semantics preserved).
  Edge-clamp delta correction (2026-05-06): `dx` / `dy` in
  motion event payloads carry the *post-clamp* delta — the
  difference between the new clamped position and the prior
  position — rather than the raw HID delta. When the cursor is
  held against an edge, payload `dx`/`dy` report 0 in that
  direction instead of the unrealised raw delta. This corrects
  the earlier "raw deltas regardless of clamping" behaviour
  that allowed phantom drift in delta-integrating consumers.
  When clamping is inactive (geometry unknown), payload
  `dx`/`dy` equal the raw input deltas as before.
- **D.4** *(landed)*: routing application. The pointer
  interrupt path resolves the session under the cursor via a
  narrow helper `inputfs_focus_resolve_pointer` (respects
  `pointer_grab` as an override; walks `surface_map` in
  z-order; returns 0 if the cache is invalid or no surface
  contains the point). When the session changes between
  consecutive reports, `pointer.leave` and `pointer.enter`
  events are synthesised with 16-byte payloads
  (`x, y, surface_id, session_id`) per
  `shared/INPUT_EVENTS.md`, carrying `flags` bit 0
  (synthesised). The report's own pointer.motion,
  pointer.button_down/up, and pointer.scroll events are
  emitted with `session_id` stamped at the documented payload
  offsets. Keyboard events derive `session_id` from
  `inputfs_focus_keyboard_session`, captured once per diff so
  all key_up / key_down events from a single report carry the
  same session. Under no compositor (focus cache invalid),
  all sessions resolve to 0 and behaviour is bit-for-bit
  compatible with Stage C / D.0a / D.0b / D.3 consumers.
- **D.5** *(landed)*: `hw.inputfs.enable` tunable. Default 1
  (publication active). When set to 0, the kthread skips
  publication-file syncs and writes `valid=0` to both file
  headers (state offset 5, events offset 5); readers detect
  the substrate as inactive via the same code path they use
  before MOD_LOAD finishes. The interrupt path keeps updating
  the in-memory buffers, so re-enabling exports the current
  pointer / device state immediately. Edge-detected by the
  kthread: a 1→0 transition writes `valid=0` once; a 0→1
  transition writes `valid=1` and forces a full state sync.
  Steady-state cost is one int read per kthread tick. Focus
  refresh runs unconditionally (the focus cache is read
  input, not output).
- **D.6** *(landed)*: Stage D verification protocol. Three
  new files: `inputfs/test/d/d-fixtures.sh` (sources
  `c-fixtures.sh` for the common module-load helpers,
  overrides the output prefix to `[d6 ...]`, adds D-specific
  helpers for state-byte / sysctl reads); `inputfs/test/d/
  d-verify.sh` (phases 0–7 covering preconditions, module
  load with optional drawfs, D.2 geometry sysctls, D.3
  transform_active byte and pointer seed, D.1 focus reader
  infrastructure, D.5 enable-tunable transitions, module
  unload); `inputfs/docs/D_VERIFICATION.md` (manual
  checklist for D.0a / D.0b under live input, D.4 routing
  with a focus writer, HID hotplug, stress test).
  D.4 routing tests are deferred to the manual checklist
  pending a synthetic focus-writer harness; the structural
  publication checks (event types, payload sizes, sequence
  monotonicity) are exercised by C.5. Verified end-to-end
  on PGSD-bare-metal: 18 automated checks pass, C.5 26
  passes preserved.

Sub-stages may interleave or merge during implementation if
dependencies surface; the breakdown is a planning aid, not a
contract. The dependency order is approximately D.0a or D.0b
first (independent of each other), then D.1 and D.2 (independent
of each other), then D.3 and D.4 (D.3 depends on D.2 and D.0a;
D.4 depends on D.1), then D.5 (depends on prior publication
work), then D.6.

## Consequences

1. The state region wire format gains a `transform_active` byte.
   Existing Stage C consumers continue to function (they read
   `pointer_x` / `pointer_y` regardless of the byte's value);
   consumers that interpret coordinates as compositor-space
   pixels gain a clean signal to gate that interpretation on.

2. The event ring wire format gains a `session_id` field in
   each per-event-type payload. The header is unchanged.
   Consumers that ignored payload bytes beyond the documented
   fields continue to work; consumers that used the documented
   layout strictly need spec-driven updates.

3. inputfs gains a runtime dependency on drawfs's sysctl
   exposure of display geometry. Failure modes (drawfs not
   loaded, sysctl absent) fall back to a conservative default
   and log; no kernel panic, no module-load failure.

4. The descriptor-parsing scope decision (touch and pen
   deferred) means Stage E cutover for touch hardware is not
   directly enabled by Stage D. Touch users will continue to
   rely on the legacy evdev path even after Stage E unless
   the deferred touch sub-item is delivered first. This is
   acknowledged and accepted: the bench's HAILUCK touchpad
   still works as a pointer through D.0a, and complex
   gesture handling was already a semainputd concern that
   doesn't migrate cleanly anyway.

5. Pointer.enter and pointer.leave events become a new event
   type emitted by inputfs's routing path. Their payload
   layout is specified in `shared/INPUT_EVENTS.md` updates
   alongside the keyboard event types.

6. The `hw.inputfs.enable` tunable creates a publication mode
   distinct from "module loaded" / "module unloaded": loaded-
   but-inert. Verification scripts and userspace consumers
   need to handle this state. The state and event ring
   `valid` bytes are the canonical signal.

7. Stage E (cutover) becomes possible only when D.6
   verification passes end-to-end. The proposal's
   "confidence built during the staged delivery and
   coexistence period" depends on D.5's tunable working
   reliably on real hardware.

## Notes

The proposal's Stage D section is older than ADR 0003 and uses
language that predates the focus region design. Where the
proposal references `DRAWFSGIOC_SET_FOCUS` or implies a
compositor-publishes-focus-via-ioctl model, this ADR governs:
the focus region is the publication mechanism, ADR 0003
specifies the interface, and inputfs reads it via shared memory.

Sub-stage numbering uses D.0a / D.0b for the descriptor-driven
work, then D.1 through D.6 for the rest. The `0a` / `0b` shape
reflects that descriptor-driven parsing is foundational work
that other sub-stages build on (D.4 routing depends on Stage D
emitting keyboard events; D.3 transform depends on Stage D
emitting descriptor-driven pointer events with proper deltas);
both could theoretically run in parallel and either could be
"first" in the timeline.

The chronofs `ts_sync` integration deferred from Stage C is
not pulled into Stage D by this ADR. ADR 0011's measurement
work depends on `ts_sync` being populated; that integration
remains a separate AD-1 sub-item, addressable independently
of Stage D sub-stages. If Stage D 's verification protocol
finds latency or jitter problems that warrant earlier
measurement, the chronofs integration may be pulled in as a
mid-Stage-D addition; otherwise it stays separate.

The verification protocol (D.6) follows C.5's pattern:
`c-verify.sh` extended (or a new `d-verify.sh`) plus a
`D_VERIFICATION.md` document with automated phases and a
manual checklist. Manual checks cover keyboard events
(D.0b), transform correctness (D.3), routing (D.4), and the
tunable's transitions (D.5).

References:
- ADR 0001 (module charter)
- ADR 0002 (shared-memory regions; transform deferral)
- ADR 0003 (focus publication interface)
- ADR 0011 (attachment-layer review; chronofs ts_sync
  measurement substrate)
- `inputfs/docs/inputfs-proposal.md` (Stage D section,
  predates ADR 0003)
- `inputfs/docs/foundations.md` §1 (coordinate space), §7
  (security and access)
- `shared/INPUT_STATE.md` (state region wire format)
- `shared/INPUT_EVENTS.md` (event ring wire format)
- `shared/INPUT_FOCUS.md` (focus region wire format)
- `shared/src/input.zig` (`FocusReader` reference
  implementation in Zig)
