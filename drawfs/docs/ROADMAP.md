# ROADMAP

## Phase 0: Specification
- Protocol definition
- State machines
- Error semantics
- Test harness

## Phase 1: Kernel Prototype (current)
- Character device protocol
- Blocking reads and poll semantics
- Display discovery and open
- Surface lifecycle
- mmap-backed surface memory
- Event queue backpressure (Step 19)
- Surface resource limits (Step 18)

### Completed work

1. Hardening and DoS resistance
   - [x] Surface size limits (EFBIG for >64MB surfaces)
   - [x] Per-session surface count limits (ENOSPC after 64 surfaces)
   - [x] Event queue backpressure (ENOSPC when queue full, recovery after drain)
   - [x] Regression tests for limits (Step 18, Step 19)

2. Test ergonomics
   - [x] Shared Python helper module (`tests/drawfs_test.py`) for framing, request building, and event parsing
   - [x] DrawSession context manager for cleaner test code
   - [x] Select-based reads to avoid indefinite blocking
   - [x] Debug tool to dump decoded frames from raw read buffer (tests/drawfs_dump.py)

### Remaining optional work

1. Code quality
   - [x] Split protocol and validation logic into dedicated C files (drawfs_frame.c, drawfs_surface.c)
   - [x] Verified consistent formatting (tabs for indentation, BSD brace style)
   - [x] Added locking rule comments to drawfs.c and drawfs_surface.c

2. Security posture
   - [x] Device node permissions configurable via sysctl (hw.drawfs.dev_uid/gid/mode)
   - [x] mmap gated by sysctl (hw.drawfs.mmap_enabled)

3. Tuning
   - [x] Event queue and surface limits tunable via sysctl (hw.drawfs.max_*)

## Phase 2: Real Display Bring-up

### EFI Framebuffer Backend (Complete)

drawfs now maps the UEFI GOP framebuffer directly from `MODINFOMD_EFI_FB`
preload metadata using `pmap_mapdev_attr` with `VM_MEMATTR_WRITE_COMBINING`,
the same technique used by `vt_efifb`. Two new ioctls expose this to userspace:

- `DRAWFSGIOC_GET_EFIFB_INFO` — query framebuffer geometry (width, height, stride, bpp)
- `DRAWFSGIOC_BLIT_TO_EFIFB` — blit a userspace pixel buffer to the framebuffer via `copyin`

`semadrawd`'s drawfs backend probes for efifb at startup via
`DRAWFSGIOC_GET_EFIFB_INFO` and calls `DRAWFSGIOC_BLIT_TO_EFIFB` after each
`SURFACE_PRESENT`, making rendered frames visible on the bare console without
X11, Wayland, or DRM/KMS. This is the mechanism by which drawfs supersedes
`vt_efifb` as the display primitive.

No GPU driver is required. The EFI framebuffer is available on any UEFI machine.

Verified operational on Intel Bay Trail at 1024x768 (FreeBSD 15, UEFI boot).

### DRM/KMS Backend (Skeleton — Hardware Bring-up Pending)

- [x] `drawfs_drm.c` skeleton with full FreeBSD KPI annotations
- [x] `hw.drawfs.backend` sysctl gate (swap/drm/efifb)
- [x] Connector enumeration and mode selection
- [x] Dumb buffer allocation and framebuffer objects
- [x] Initial mode set via `DRM_IOCTL_MODE_SETCRTC`
- [x] Page-flip present path via `DRM_IOCTL_MODE_PAGE_FLIP`

`drawfs_drm.c` is excluded from the default build — it requires `drm-kmod`
headers which are not part of the FreeBSD base system. To enable, install
`drm-kmod`, add `CFLAGS+=-DDRAWFS_DRM_ENABLED` and `drawfs_drm.c` to `SRCS`.

Remaining items for DRM bring-up:

- [ ] Flip completion event handler (kthread to clear flip_pending)
- [ ] Damage rect filtering in `SURFACE_PRESENT` (partial update optimisation)
- [ ] Atomic modesetting (`drmModeAtomicCommit`) for HDR and VRR support
- [ ] Multi-GPU / multi-connector enumeration

## Operational Status

drawfs Phase 1 is verified operational on bare metal FreeBSD 15.0-RELEASE-p5
at 1920x1080@60Hz using the swap backend. The module builds cleanly, loads
via `kldload`, creates `/dev/draw`, and semadrawd successfully negotiates
the protocol, creates a surface, and maps it for rendering.

drawfs Phase 2 (EFI framebuffer backend) is verified operational on Intel
Bay Trail at 1024x768 under UEFI boot. Rendered frames are blitted directly
to the physical display via `DRAWFSGIOC_BLIT_TO_EFIFB` without X11 or DRM.

## Phase 3: User Environment
- Reference compositor
- Window management
- Input integration

## Phase 4: Optimization
- Zero-copy paths
- GPU acceleration
- Scheduling and batching

## Backlog

### Completed

- [x] Hardening: Event coalescing for repeated SURFACE_PRESENTED events (hw.drawfs.coalesce_events)
- [x] Correctness: Stress tests for surface lifecycle (stress_surface_lifecycle.py)
- [x] Concurrency: Multi-session stress tests with parallel/interleaved operations (stress_multi_session.py)
- [x] Memory lifecycle: Validation tests using vmstat -m (test_memory_lifecycle.py)
- [x] Observability: Expose per-session counters (evq_bytes, surfaces_count, surfaces_bytes) in stats ioctl (test_observability.py)
- [x] Compatibility: Verified on FreeBSD 15.0-RELEASE-p1 (non-debug kernel) - all tests pass
- [x] Memory lifecycle validation: Debug sysctl counters for vm_object tracking (hw.drawfs.vmobj_allocs/deallocs, test_vmobj_counters.py)

### Remaining

- Compatibility: Test on FreeBSD 15 debug kernel (WITNESS enabled) when available.
