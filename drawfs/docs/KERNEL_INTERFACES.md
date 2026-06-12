# Kernel Interfaces

This document describes the FreeBSD kernel behavior of `/dev/draw`.

## Device node

* Path: `/dev/draw`
* Type: character device
* Access: root for early development, later tightened by devfs rules and policy

## Open and close

* `open` allocates a session.
* `close` frees session state, surfaces, and backing objects.

## Write

* Accepts arbitrary chunking.
* Buffers incomplete frames.
* Validates frame headers and message headers.
* Processes complete messages in order.

## Read

* Returns queued replies and events.
* If the queue is empty, blocks unless nonblocking mode is requested.
* The unit of data returned is an encoded frame that wraps one reply message today.
  Future implementations may bundle replies and events per read.

## poll and kqueue

* Readable when at least one reply or event is queued.

## ioctl

Implemented ioctls.

`DRAWFSGIOC_STATS` — returns per-session counters for frames, messages, events,
and bytes, plus current resource usage (surfaces_count, surfaces_bytes,
evq_bytes).

`DRAWFSGIOC_MAP_SURFACE` — selects a surface for `mmap` on this file descriptor.
The caller sets `surface_id`; the kernel fills `stride_bytes` and `bytes_total`.

`DRAWFSGIOC_INJECT_INPUT` — injects an input event into the session that owns
a given surface. Used by semainputd to route keyboard, pointer, scroll, and
touch events to the correct client.

`DRAWFSGIOC_GET_EFIFB_INFO` — queries EFI framebuffer geometry when the efifb
backend is active. Returns width, height, stride, bits per pixel, and total
size. Returns `ENODEV` if no EFI framebuffer is available.

`DRAWFSGIOC_BLIT_TO_EFIFB` — copies a userspace pixel buffer to the EFI
framebuffer via `copyin`. The caller provides a pointer to the rendered pixel
data, source stride, dimensions, and destination offset. The kernel copies
each row to the write-combining framebuffer mapping. Called by semadrawd after
each `SURFACE_PRESENT` when the efifb backend is active. Returns `ENODEV` if
efifb is not initialised, `EFAULT` on bad pointer.

## mmap

* `mmap` is supported via `d_mmap_single`.
* Mapping must use offset 0.
* Mapping size must be nonzero and must not exceed the selected surface bytes_total.
* Memory is swap backed and shared between kernel and user space.

## Error reporting

Protocol replies use FreeBSD errno values.

Clients must not hardcode numbers from other systems.
