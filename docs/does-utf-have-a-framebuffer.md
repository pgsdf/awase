# Does UTF have a framebuffer?

*A short question about UTF's graphics stack turns out to have a
surprisingly long answer. It's worth writing up, because the answer
illuminates the architecture.*

---

## The short answer

Yes, but not in the sense most people mean.

UTF's kernel module, `drawfs`, provides per-surface framebuffers as
`mmap(2)`-able swap-backed pixel buffers. Every live surface is a
framebuffer. A process can have dozens of them simultaneously.

It does **not** provide a global system framebuffer. There is no
`/dev/fb0`. The kernel never scans pixels out to hardware. Composition
and display live in userspace, by design.

In the optional DRM/KMS build — disabled by default, opted into at
`configure` time — `drawfs` can additionally allocate GEM dumb
buffers and drive page-flips. That is the only place in UTF where a
framebuffer in the strict "the display controller is scanning this
memory right now" sense exists, and it is absent from a default build.

That's the summary. If you stopped reading here you'd have the right
mental model. The rest of this post is about *why* the architecture
splits the concept this way, and what it costs and buys.

---

## What "framebuffer" even means

The word is overloaded. Four meanings worth separating:

1. **Pixel-grid memory.** A contiguous array of pixels in a known
   format. This is the most literal meaning. Any `malloc(w*h*4)` is
   a framebuffer under this definition.

2. **Kernel-owned display memory.** The canonical Linux `fbdev` model:
   one system-wide object (`/dev/fb0`) representing the screen, writable
   by anyone with permission, scanned out by the hardware, resolution
   and pixel format are global state.

3. **Hardware scanout buffer.** Whatever physical memory the display
   controller is reading pixels from this millisecond, whether that's
   a CRTC-attached plane in a DRM driver, a BAR region on a graphics
   card, or a reserved chunk of RAM on an embedded platform. This is
   the most concrete meaning — "the bytes the pixels come out of."

4. **Compositor output buffer.** The rectangle the compositor paints
   into before presenting. On Wayland this is a `wl_buffer`; on X11
   it's the root window's backing pixmap or the composite extension
   off-screen pixmap.

UTF has (1), deliberately avoids (2), has (3) only when the optional
DRM path is compiled in, and treats (4) as a pluggable userspace
concern. Each of these choices is architectural, not accidental.

---

## Per-surface framebuffers: the swap-backed mmap path

The default drawfs path is swap-backed. It works like this:

```
  client              kernel (drawfs.ko)         VM subsystem
    │                      │                          │
    ├─ CREATE_SURFACE ────▶│                          │
    │  (w, h, fmt)         │                          │
    │                      ├─ vm_pager_allocate ─────▶│
    │                      │  (OBJT_SWAP, w*h*4)      │
    │                      │◀──── vm_object *obj ─────┤
    │                      │                          │
    │◀── SURFACE_CREATED ──┤                          │
    │  (surface_id)        │                          │
    │                      │                          │
    ├─ MAP_SURFACE ───────▶│                          │
    │  (surface_id)        │                          │
    │                      │ cdev_pager_allocate      │
    │                      │ bound to obj             │
    │◀── mmap cookie ──────┤                          │
    │                      │                          │
    ├─ mmap(fd, ...) ──────────────────────────────▶  │
    │◀── user VA ──────────────────────────────────── │
    │                                                 │
    │── writes pixels at user VA ─────────────────▶   │
    │                                                 │
    ├─ SURFACE_PRESENT ───▶│                          │
    │  (surface_id)        │                          │
    │                      │  (emits event;           │
    │                      │   no pixel copy)         │
```

A `drawfs` session can hold up to 64 surfaces
(`DRAWFS_MAX_SURFACES`), each up to 64 MiB (`DRAWFS_MAX_SURFACE_BYTES`),
with a cumulative per-session cap of 256 MiB
(`DRAWFS_MAX_SESSION_SURFACE_BYTES`). The memory is paged through the
normal VM subsystem — it can be swapped out, it respects RLIMIT_DATA
at creation, and unmapping is handled by the usual `vm_object`
refcounting. There is nothing special about this memory from the
kernel's point of view. It's just paged anonymous memory, reachable
through a character device's `d_mmap_single` handler.

This means, under meaning (1) above, drawfs has *many* framebuffers.
The count is `sum over open sessions of that session's surface count`.
They are isolated: one client cannot see another client's pixels.
They are flexible: any client can have any size, any time, at any
pixel format drawfs supports. And they cost the kernel no display
hardware knowledge — the kernel does not know, and does not need to
know, what pixels are for.

What drawfs pointedly does *not* do:

- Scan pixels out to a monitor.
- Tell the hardware anything about resolution or refresh rate.
- Allocate physically contiguous memory.
- Guarantee any latency or presentation timing.

The `SURFACE_PRESENT` request is a metadata operation. It tells the
kernel "this buffer is done for now." A `SURFACE_PRESENTED` event
gets enqueued to every session subscribing to that surface. **No
pixels get copied anywhere in response to `SURFACE_PRESENT` itself.**
The pixels stay in swap memory until something — `semadrawd`, typically
— comes along and reads them out.

This is the single most important thing to understand about drawfs.
It is not a display API. It is a pixel memory broker. Display is
someone else's job.

---

## Why not a global `/dev/fb0`?

Because `/dev/fb0` carries three assumptions that don't hold in a
semantic multimedia substrate:

- **One screen, one resolution, one format, globally agreed.** UTF
  wants per-surface coordinate systems, resolution independence, and
  the ability for different consumers (a terminal, a video decoder,
  a DRM driver) to see different things at different times.
- **Writes are presentations.** In fbdev, the act of writing pixels
  to the mapping is the act of making them visible. That fuses two
  separate decisions (rendering vs presenting) that UTF wants kept
  apart, not least because the chronofs temporal fabric wants to
  schedule *when* something becomes visible relative to an audio
  sample clock.
- **There is one consumer: the display controller.** UTF's consumers
  include `semadrawd` in software mode (paints into its own
  memory), `semadrawd` in Vulkan mode (uploads to a GPU texture),
  `semadrawd` in Wayland mode (attaches to a `wl_buffer`), and a
  future `drawfs` DRM mode (flips to a CRTC). Each of these
  treats the drawfs surface memory as an *input*, not as a screen.

The consequence of the design is that the kernel stays small and
ignorant. `drawfs.ko` is ~1200 lines of C plus a protocol header.
It doesn't link against `drm-kmod`. It doesn't know what a monitor
is. It doesn't need to. It just vends memory.

---

## Where the pixels actually go

A drawfs surface's pixels reach a human's eyes via whichever
userspace backend `semadrawd` is configured to use. Here is the
full picture for the default (swap-only) build:

```
  Application                    semadrawd                    Backend
  ─────────────                  ─────────                    ───────
                                                              software:
                                                                in-memory byte
  ┌──────────┐                  ┌───────────┐                  array, no scanout
  │ drawfs   │  SDCS stream     │ composite │                  (CI, golden tests)
  │ surface  │ ───────────────▶ │   engine  │
  │ (mmap'd  │                  │           │                  x11:
  │  pixels) │                  │  reads    │─────▶            XShmPutImage
  └──────────┘                  │  surfaces │                  into an X window
                                │  + z order│
                                │  + damage │                  wayland:
                                └───────────┘                  wl_buffer attach
                                                               + wl_surface commit

                                                               vulkan_console:
                                                               VK_KHR_display
                                                               + vkQueuePresent

                                                               drawfs (loopback):
                                                               SDCS into another
                                                               drawfs surface
```

The split is what makes the architecture honest about layering.
`drawfs` owns "memory for pixels." `semadrawd` owns "what pixels
to put there and when." The backend owns "how those pixels get
to hardware." Three different abstractions, three different
teams-of-concepts, three different sets of failure modes.

There is no architectural level at which the question "what's the
framebuffer?" has a single answer — because the design refuses to
conflate them.

---

## The optional DRM path

`drawfs_drm.c` implements a second backend *inside the kernel module*
itself. It's Phase 2 work, off by default, guarded by
`-DDRAWFS_DRM_ENABLED` and the `.if defined(DRAWFS_DRM_ENABLED)`
block in both Makefiles. Enabling it in the build produces a
`drawfs.ko` that *additionally* knows how to:

- Open `/dev/dri/card0` and negotiate a display mode.
- Allocate GEM dumb buffers (`DRM_IOCTL_MODE_CREATE_DUMB`).
- Bind a surface's pixels to a dumb buffer on present.
- Page-flip via `drmModePageFlip`, respecting vblank.

At runtime, which backend a surface uses is selected by the
`hw.drawfs.backend` sysctl, which defaults to `"swap"`. Setting it
to `"drm"` and reloading the module activates the DRM path *if
drm-kmod loaded successfully*. If DRM init fails at module load,
the module logs a warning, resets the sysctl to `"swap"`, and
continues. A broken GPU driver cannot prevent `drawfs.ko` from
loading.

This is the only UTF code path where meaning (3) of "framebuffer" —
hardware scanout buffer — is present. It's opt-in for a specific
reason: the project's primary invariant is that the DRM-less swap
path is the unbreakable default. Adding a hard dependency on
`drm-kmod` headers for every drawfs build would tie the project's
fate to whichever DRM driver branch happens to be current on the
target system. It is a pragmatic non-goal, not a philosophical
objection.

If you want the DRM path:

```
sh configure.sh          # check "drawfs DRM/KMS backend"
sh install.sh
sysctl hw.drawfs.backend=drm
kldload drawfs
```

If you don't, you never see it. The default build produces a
`drawfs.ko` with `grep -i drm` against the binary returning empty.

---

## So, does UTF have a framebuffer?

Pick your definition:

| Meaning | Present in UTF? |
|---|---|
| Pixel-grid memory | Yes — every drawfs surface |
| Kernel-owned global display memory (`/dev/fb0`) | No, by design |
| Hardware scanout buffer | Only when the optional DRM path is built and activated |
| Compositor output buffer | Yes, owned by `semadrawd`, backend-dependent |

The most useful one-line answer for a BSD/kernel audience:

> drawfs provides per-surface framebuffers as swap-backed mmap regions.
> The system has no global framebuffer; composition and display are
> userspace concerns. A hardware-backed framebuffer exists only in
> the optional DRM build path.

The deeper answer is that UTF's architecture rejects the
"framebuffer" abstraction as a useful unit of analysis. The question
"where is the framebuffer" presupposes a single answer. The system
is built on the premise that there isn't one, and that refusing to
pick one is what makes the rest of the architecture — SDCS command
streams, audio-clock-driven frame scheduling, swappable backends —
possible in the first place.

---

*UTF is BSD-2-licensed and developed at the Pacific Grove Software
Distribution Foundation. See https://github.com/pgsdf/UTF for
sources.*
