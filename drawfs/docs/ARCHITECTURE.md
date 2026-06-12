# Architecture

drawfs provides a minimal semantic graphics interface for FreeBSD.

At a high level, drawfs separates mechanism from policy.

## Components

* Kernel device: `/dev/draw`
  * Parses and validates frames and messages
  * Tracks session scoped objects (displays, surfaces)
  * Queues replies and events
  * Provides blocking read and readiness notification
  * Provides surface backing memory via `mmap` (Step 11)
* Optional user space policy daemon: `drawd` (planned)
  * Focus and input routing
  * Multi client composition policy
  * Security policy, permissions, and isolation
* Client libraries (planned)
  * Frame and message encode decode
  * Capability negotiation helpers
  * Convenience wrappers for surfaces and presentation

## Data flow

1. A client opens `/dev/draw` and sends `HELLO`.
2. The client queries `DISPLAY_LIST` and then `DISPLAY_OPEN`.
3. The client creates one or more surfaces.
4. The client selects a surface for mapping and uses `mmap` to obtain a writable pixel buffer.
5. The client renders into the mapped buffer.
6. Presentation semantics are added in a later step (planned).

## Objects and lifetimes

* Session
  * One open file descriptor is one session.
  * All objects are session scoped.
  * Closing the fd frees session resources.
* Display
  * A display id is enumerated from `DISPLAY_LIST`.
  * `DISPLAY_OPEN` activates a display for the session.
* Surface
  * Created after a display is active.
  * Backed by memory and mapped to user space.
  * Explicitly destroyed or freed when the session closes.

## Concurrency and ordering

* Writes are accepted in any chunking.
* Frames and messages are processed in order per session.
* Replies are emitted in order of processing.
* `read` blocks when no replies are queued unless nonblocking is requested.
* `poll` and `kqueue` indicate readability when replies or events are queued.

## Security posture

drawfs aims to be auditable and to keep kernel responsibilities narrow.

* Kernel code does not implement window management.
* Kernel code does not implement compositing policy.
* Kernel code does not expose raw input devices to clients.

## DRM/KMS Backend (DF-3)

The DRM/KMS backend provides real hardware display output, replacing the
swap-backed vm_object path with GPU dumb buffers scanned out directly by the
display engine.

### Selection

The backend is chosen via the `hw.drawfs.backend` sysctl:

```
sysctl hw.drawfs.backend=drm   # enable DRM
sysctl hw.drawfs.backend=swap  # revert to vm_object (default)
```

Changes take effect for new `DISPLAY_OPEN` calls. Open displays are not
affected until they are closed and re-opened.

### Initialisation

On `MOD_LOAD`, drawfs calls `drawfs_drm_init()` if the backend sysctl is
already set to `"drm"`. If DRM init fails (no `/dev/dri/card0`, no dumb
buffer capability), drawfs reverts the sysctl to `"swap"` and logs a
warning — module load is not aborted.

### DISPLAY_OPEN with DRM

`drawfs_reply_display_open()` checks `drawfs_backend`:

1. **Connector enumeration** — `DRM_IOCTL_MODE_GETRESOURCES` lists all
   connectors and CRTCs. The first connected connector is selected.
2. **Mode selection** — the first mode in the connector's mode list (the
   preferred mode reported by the monitor's EDID) is used.
3. **Dumb buffer allocation** — two buffers are allocated
   (`DRM_IOCTL_MODE_CREATE_DUMB`) at the mode resolution in XRGB8888 format.
   The stride returned by the ioctl is hardware-aligned and may be wider
   than `width_px × 4`.
4. **Framebuffer objects** — each dumb buffer is wrapped with
   `DRM_IOCTL_MODE_ADDFB` to create an FB id the CRTC can scan out.
5. **Mode set** — `DRM_IOCTL_MODE_SETCRTC` enables the CRTC with the front
   buffer, starting display output.

The resulting `drawfs_drm_display` struct is stored per session.

### SURFACE_PRESENT with DRM

1. Pixel data is copied from the surface's `vm_object` into the back dumb
   buffer using DMAP access (`PHYS_TO_DMAP(VM_PAGE_TO_PHYS(pg))`).
2. `DRM_IOCTL_MODE_PAGE_FLIP` schedules a vblank-synchronised swap.
3. Front and back buffer handles are swapped for the next frame.
4. If a flip is already pending, the present is dropped rather than queuing
   a second flip. (Future: buffer the pending present and re-issue on flip
   completion.)

### Damage tracking

When `damage_count > 0` in the `SURFACE_PRESENT` payload, only the listed
rectangles are copied from the vm_object to the dumb buffer. Full-surface
copy is used when `damage_count == 0`. This is implemented in
`drawfs_drm_surface_present()` but the rectangle-filtered path is marked
as TODO in the current skeleton.

### Data flow (DRM backend)

```
Client renders into mmap'd vm_object
    ↓
SURFACE_PRESENT
    ↓
drawfs_drm_surface_present()
    ↓
vm_object → DMAP → dumb buffer (back)
    ↓
DRM_IOCTL_MODE_PAGE_FLIP (vblank-synchronised)
    ↓
Monitor receives new frame
```

### Files

| File              | Role                                    |
|-------------------|-----------------------------------------|
| `drawfs_drm.h`    | Interface between drawfs.c and DRM backend |
| `drawfs_drm.c`    | DRM/KMS backend implementation         |
| `drawfs.c`        | Sysctl gate, init/fini hooks            |
