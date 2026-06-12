# ADR 0002: DF-6, DRM backend runtime wiring

## Status

Accepted 2026-06-07, operator-ratified (D1 through D6). For D3 the
nested-lock approach is taken first, with VM object pinning recorded
as the first optimization/refactor if lock hold time becomes an
issue under real workloads.

Runtime verification is BLOCKED on DRM/KMS-capable hardware, which is
not currently available; this implementation may be reviewed and
merged before that verification occurs, but DF-6 is not considered
validated until it has been exercised on supported hardware.

This ADR designs DF-6 (BACKLOG.md): connecting the DF-3 DRM/KMS
skeleton to the live SURFACE_PRESENT path so that, with
`hw.drawfs.backend=drm` on KMS hardware, a client present drives a
real page flip. It also lands the AD-18.7 locking fix, whose
calling site DF-6 creates.

## Context

A read of the current tree establishes the following ground truth,
which is larger in scope than the DF-6 entry's original "connect the
two functions" framing.

  - `drawfs_drm.c` carries a full skeleton: `drawfs_drm_display_open`,
    `drawfs_drm_display_close`, and `drawfs_drm_surface_present`
    (connector enumeration, mode set, dumb-buffer allocation, page
    flip). All three are unreached: `grep` finds no caller of
    `drawfs_drm_display_open` or `drawfs_drm_surface_present`.
  - The session struct has no DRM-display field, and there is no
    global display accessor. Nothing stores the
    `struct drawfs_drm_display *` that `display_open` returns. The
    display lifecycle does not exist; only the backend selector
    sysctl (`drawfs_backend`, default "swap") is present.
  - `drawfs_reply_surface_present` (drawfs.c) looks the surface up
    via `drawfs_surface_lookup`, which acquires `s->lock`, walks,
    and RELEASES the lock before returning the pointer. The returned
    `surf` is therefore unprotected against a concurrent
    SURFACE_DESTROY; it is used only to set the reply today, so the
    bare pointer is currently harmless, but a DRM present would
    dereference `surf->vmobj`, `surf->width_px`, `surf->stride_bytes`
    after the lock is dropped.
  - `drawfs_drm_surface_present` holds `dd->drm_mtx` across the whole
    body: the full-surface pixel copy into `dd->back_map`, the
    `drm_ioctl_kern(DRM_IOCTL_MODE_PAGE_FLIP, ...)` call, the
    `flip_pending = 1` set, and the front/back swap. The ioctl under
    the lock is exactly AD-18.7.
  - `dd->flip_pending` is set on a successful flip but nothing clears
    it; there is no flip-completion path.

Verification requirement: DF-6 requires a DRM/KMS-capable
environment for runtime verification, which is not currently
available (the PGSD machines run `efifb` only; the last install
logged "DRM/KMS backend: false"). The feature is designed for the
real hardware UTF expects to support, and that hardware is the
intended validation target. The implementation may be reviewed and
merged before verification occurs, but validation remains
outstanding until hardware testing is performed. The risks this ADR
addresses, display ownership and lifecycle, surface lifetime, lock
ordering, flip-state management, and completion handling, are
architectural and can be reasoned about, reviewed, and implemented
today; hardware may later expose integration or driver-specific
behaviour but is unlikely to change the core decisions. The code is
written correct-by-construction and audited against the locking
model; it is not claimed verified until the hardware bench runs.

## Decisions

### D1: a single global DRM display, opened lazily

The screen is one physical resource owned by one compositor; clients
present through it. So the DRM display is global, not per-session.

  - Add a file-global `static struct drawfs_drm_display *g_drm_display`
    in drawfs.c, NULL until opened, guarded by a dedicated
    `drawfs_drm_display_mtx` (not `drawfs_global_mtx`, to keep the
    session-registry lock's order independent of the display lock).
  - Open it lazily: the first time a session selects a display
    (SET_DISPLAY handler, where `s->active_display_id` is assigned)
    while `drawfs_backend` is "drm" and `g_drm_display == NULL`, call
    `drawfs_drm_display_open(display_id, ...)` and store the result.
    A failed open leaves `g_drm_display == NULL` and the present path
    falls through to the swap backend (no regression).
  - Close it at module unload (and on an explicit backend change back
    to swap, if that path is added later) via
    `drawfs_drm_display_close`.

Alternative considered: a per-session display pointer. Rejected, it
multiplies a singleton, complicates teardown, and misrepresents the
hardware (N sessions do not own N screens).

### D2: dispatch in reply_surface_present, gated and non-regressing

In the success block of `drawfs_reply_surface_present` (after the
lookup succeeds, before `send_reply`), when `drawfs_backend` is "drm"
and `g_drm_display != NULL`, drive the DRM present. Otherwise behave
exactly as today (swap backend). The reply and the SURFACE_PRESENTED
event are still sent regardless of backend, so client protocol
behaviour is unchanged; only the pixel destination differs.

### D3: surf lifetime and lock order, s->lock then drm_mtx

The present must not dereference a surface that SURFACE_DESTROY could
free underneath it. Decision: hold `s->lock` across the DRM present
so the surface and its `vmobj` stay alive, using the
`drawfs_surface_lookup_locked` variant (AD-18.1) under a held lock
rather than the unlocked `drawfs_surface_lookup`. The DRM present
acquires `dd->drm_mtx` inside that hold, establishing the global lock
order

    s->lock  ->  drawfs_drm_display_mtx (open/close)  and
    s->lock  ->  dd->drm_mtx (present)

No DRM path acquires a session lock, so no inversion exists; WITNESS
will learn this order on the first present. The order is documented
in the drawfs.c locking-model comment block (the same block AD-18.5
and AD-18.6 reference).

Alternative considered: pin the surface's `vmobj`
(`vm_object_reference`) under `s->lock`, drop the lock, then present
without nesting. This matches the AD-18.2 "capture, release, slow
call" shape and avoids holding `s->lock` across a full-surface copy.
It is the better long-term shape if `s->lock` hold time proves
costly, but it adds a reference/teardown dance and a second
re-validation. Deferred: D3 takes the simpler nested-lock approach
first (correctness over latency), with the pin refactor recorded as
a follow-up if the hold time bites.

### D4: AD-18.7, lift the page-flip ioctl out of the drm_mtx hold

Refactor `drawfs_drm_surface_present` to the established
capture/claim, release, slow-call, re-acquire, install-or-rollback
shape (as AD-18.2/.3/.4):

  1. Lock `drm_mtx`. If `flip_pending`, unlock and return 0 (drop
     frame, unchanged). If `back_map == NULL`, unlock and return
     ENXIO (unchanged).
  2. Copy pixels into `back_map` under the lock (unchanged; the copy
     touches `dd` state and must stay serialized).
  3. Capture the flip parameters (`crtc_id`, `back_fb_id`) into
     locals and CLAIM the in-flight slot by setting
     `dd->flip_pending = 1` BEFORE dropping the lock, so a concurrent
     present on another session sees the claim and drops its frame.
     Release `drm_mtx`.
  4. Call `drm_ioctl_kern(DRM_IOCTL_MODE_PAGE_FLIP, ...)` unlocked.
  5. Re-acquire `drm_mtx`. On ioctl error: ROLL BACK
     `flip_pending = 0`, log once (the AD-13.3 gate), unlock, return
     the error. On success: clear `flip_failure_logged`, perform the
     front/back swap, leave `flip_pending = 1` (the completion path
     clears it), unlock, return 0.

This removes the ioctl from under the lock while preserving the
single-flight invariant via the pre-drop claim.

### D5: flip completion, kthread skeleton

A page flip requested with `DRM_MODE_PAGE_FLIP_EVENT` completes with a
`DRM_EVENT_FLIP_COMPLETE` on the DRM event queue. Without consuming
it, `flip_pending` never clears and every subsequent present drops.
DF-6 adds a per-display completion kthread skeleton that, when fully
implemented, reads the event queue and clears `flip_pending` on
completion. The initial landing may stand up the kthread lifecycle
(create at display open, signal-and-join at close) with the
event-queue read stubbed or minimal; full event handling can be
incremental. This is called out so the first bench knows
`flip_pending` clearing may be the kthread's incomplete half.

### D6: damage stays full-surface

`drawfs_drm_surface_present` already ignores `damage`/`damage_count`
and copies the full surface. DF-6 keeps that; per-rectangle damage on
the DRM path is out of scope and tracked with B3.4-B3.5.

## Consequences

  - AD-18.7 closes here (its calling site now exists and the fix
    lands with it). AD-18 can then close, its audit fully discharged.
  - A new documented lock order (`s->lock` -> `drm_mtx`) enters the
    locking model; WITNESS validates it under the bench.
  - No behaviour change on swap/efifb machines: every new path is
    gated on `drawfs_backend == "drm"` and a non-NULL global display.
  - The bench is owed and BLOCKED on DRM/KMS-capable hardware, the
    intended validation target. Until that hardware test runs, DF-6
    is "written, not verified."

## Bench criteria (deferred to DRM/KMS hardware)

  - Under PGSD-DEBUG with WITNESS: sustained SURFACE_PRESENT workload
    produces no lock-order warning (validating D3).
  - `hw.drawfs.vmobj_allocs == hw.drawfs.vmobj_deallocs` across the
    run (no surface leak through the present path).
  - `flip_pending` returns to 0 between presents once D5's kthread
    reads completions; front/back pointers remain consistent across
    many cycles.
  - With `hw.drawfs.backend=swap`, behaviour is byte-identical to
    pre-DF-6 (regression guard); this one is verifiable on the
    current efifb machines and is the pre-merge gate.
