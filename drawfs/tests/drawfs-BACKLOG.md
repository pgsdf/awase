# drawfs Backlog

`drawfs` is the kernel spatial substrate: the `/dev/draw` character device that
provides surface creation, mmap-backed pixel buffers, and the framed binary
protocol that semadraw's drawfs backend speaks. The protocol-level critical fixes
are already complete (per `semadraw/BACKLOG.md`). The remaining work is Phase 2
display bring-up and the integration surface with semadraw.

---

## DF-1 — Verify Integration Against Repaired semadraw drawfs Backend

**Status**: Done
**Effort**: Small
**Depends on**: semadraw BACKLOG.md items 1.3 and 1.4 (SDCS opcodes and ioctl
  fix — both already marked done)

### Background

The protocol fixes in semadraw's drawfs backend (SDCS opcode expansion, ioctl
comptime encoding) were done in isolation without a running kernel module to test
against. This item is an integration smoke test: build the kernel module, load
it, run the semadraw drawfs backend against it, and confirm all the newly
implemented SDCS opcodes produce correct output on a real mapped surface.

### Tasks

- [ ] Build and load `drawfs.ko` on a FreeBSD 15 system
- [ ] Run `semadraw` configured to use the drawfs backend
- [ ] Emit an SDCS stream exercising: `RESET`, `SET_BLEND`, `SET_ANTIALIAS`,
      `FILL_RECT`, `STROKE_RECT`, `STROKE_LINE`, `END`
- [ ] Confirm the surface pixel buffer contains expected output (compare against
      the software renderer golden images)
- [ ] Document any discrepancies as new bug items
- [ ] Add a Python integration test in `drawfs/tests/` that loads the module and
      runs the above sequence

### Acceptance Criteria

- Integration test passes on FreeBSD 15.0-RELEASE-p1
- No kernel panics or assertion failures during the test run
- Surface pixel output matches software renderer for `FILL_RECT` and
  `STROKE_RECT` at minimum

---

## DF-2 — Input Event Delivery

**Status**: Open
**Effort**: Medium
**Depends on**: semainput I-1 (semainput producing stable structured output)

### Background

`drawfs/docs/DESIGN.md` lists input events as planned but not implemented.
Currently `/dev/draw` delivers no events to clients — the reply queue carries
only protocol replies. To close the loop between semainput's structured gesture
and semantic events and the application that owns a drawfs surface, drawfs needs
to deliver input events to the session that owns the focused surface.

This is a kernel addition. The event format should use the unified schema from
shared/S-2 where possible, but within the kernel context must use the existing
framed binary format.

### Tasks

- [ ] Define input event message types in `drawfs_proto.h` (in the `0x9xxx`
      event range from `shared/protocol_constants.json`):
  - `EVT_KEY` (0x9010) — key press/release
  - `EVT_POINTER` (0x9011) — pointer move + button state
  - `EVT_SCROLL` (0x9012) — scroll delta
  - `EVT_TOUCH` (0x9013) — touch contact down/move/up
- [ ] Add to `drawfs.c`: a kernel-side input injection path — an ioctl
      (`DRAWFSGIOC_INJECT_INPUT`) that an input daemon (or a bridge daemon) can
      call to deliver an event to a specific session's reply queue
- [ ] Update `drawfs_proto.h` with the new ioctl and event structs
- [ ] Update `shared/protocol_constants.json` to include the new event types
- [ ] Add Python tests in `drawfs/tests/` for event delivery and queue
      backpressure under input load
- [ ] Document in `drawfs/docs/INPUT_MODEL.md` (already exists as a stub)

### Acceptance Criteria

- A test client can receive `EVT_KEY` events injected via the ioctl
- Event delivery does not block the rendering path
- Backpressure behavior (queue full) matches the existing surface event
  backpressure behavior

---

## DF-3 — DRM/KMS Display Bring-up (Phase 2)

**Status**: Open
**Effort**: Large
**Depends on**: DF-1 (baseline integration working)

### Background

Phase 2 in `drawfs/docs/ROADMAP.md`. Currently `/dev/draw` manages surfaces in
swap-backed memory but has no path to actual display hardware. DRM/KMS
integration gives drawfs a real display output, turning it from a protocol
prototype into a functional display substrate.

### Tasks

- [ ] Research FreeBSD DRM/KMS API availability in FreeBSD 15 (`/dev/dri/`,
      `drm.h`)
- [ ] Add a `drawfs_drm.c` backend that:
  - Enumerates connectors and CRTCs via DRM
  - Sets mode on `DISPLAY_OPEN`
  - Allocates dumb buffers for surfaces (replacing swap-backed vm objects for
    the presented surface)
  - Performs page flip on `SURFACE_PRESENT`
- [ ] Gate the DRM backend behind a `hw.drawfs.backend` sysctl (values:
      `"swap"` for current behavior, `"drm"` for hardware)
- [ ] Add damage tracking support: accept a damage rectangle list on
      `SURFACE_PRESENT` to enable partial updates
- [ ] Update `drawfs/docs/ARCHITECTURE.md` with the DRM backend description

### Acceptance Criteria

- With `hw.drawfs.backend=drm`, a test client can display a colored rectangle
  on a connected monitor
- Switching back to `hw.drawfs.backend=swap` reverts to the existing behavior
- No regression in existing Python test suite
