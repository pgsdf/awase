# Input Model

This document defines the input event delivery model for drawfs. Input event
injection is implemented as of DF-2.

---

## Architecture

Input events are delivered to drawfs sessions through a kernel injection path.
A privileged bridge daemon (typically an extension of `semainputd` or a
dedicated input router) receives structured input events from `semainput`, maps
them to the focused surface, and injects them into the kernel via ioctl. The
kernel enqueues the events on the owning session's read queue, where they arrive
interleaved with protocol replies on the same file descriptor the application
already polls.

```
semainputd  →  input bridge daemon  →  DRAWFSGIOC_INJECT_INPUT ioctl
                                              ↓
                                    drawfs kernel module
                                              ↓
                              session event queue (evq)
                                              ↓
                                  application read()
```

No raw input device access is exposed to applications. Input routing is a
policy decision made entirely in userspace by the bridge daemon.

---

## Event types

All input event types use the 0x9xxx range, consistent with EVT_SURFACE_PRESENTED (0x9002).

| Type | Value | Description |
|------|-------|-------------|
| EVT_KEY | 0x9010 | Key press or release |
| EVT_POINTER | 0x9011 | Pointer move and button state |
| EVT_SCROLL | 0x9012 | Scroll delta |
| EVT_TOUCH | 0x9013 | Touch contact down, move, or up |

---

## Injection ioctl

```c
#define DRAWFSGIOC_INJECT_INPUT _IOWR('D', 0x03, struct drawfs_inject_input)

struct drawfs_inject_input {
    uint32_t surface_id;                        /* target surface */
    uint16_t event_type;                        /* DRAWFS_EVT_* */
    uint16_t _pad;
    uint8_t  payload[DRAWFS_INPUT_PAYLOAD_MAX]; /* event-specific payload */
};
```

The caller fills surface_id and event_type, then places the appropriate event
payload in payload. The kernel:

1. Validates event_type against the known set.
2. Searches the global session registry for the session owning surface_id.
3. Enqueues a framed event message on that session's read queue.
4. Returns ENOENT if the surface is not found, ENOSPC if the target queue
   is full, EINVAL for an unrecognised event type.

The injector does not need to hold the target session's fd.

---

## Event payload structs

### EVT_KEY (0x9010) — 24 bytes

```c
struct drawfs_evt_key {
    uint32_t surface_id;
    uint32_t code;        /* evdev key code */
    uint32_t state;       /* 1=down, 0=up */
    uint32_t mods;        /* Shift=1 Ctrl=2 Alt=4 Meta=8 */
    int64_t  ts_wall_ns;
} __packed;
```

### EVT_POINTER (0x9011) — 32 bytes

```c
struct drawfs_evt_pointer {
    uint32_t surface_id;
    int32_t  x;           /* surface-relative x */
    int32_t  y;           /* surface-relative y */
    int32_t  dx;          /* relative motion delta */
    int32_t  dy;
    uint32_t buttons;     /* left=1 right=2 middle=4 */
    int64_t  ts_wall_ns;
} __packed;
```

### EVT_SCROLL (0x9012) — 20 bytes

```c
struct drawfs_evt_scroll {
    uint32_t surface_id;
    int32_t  dx;
    int32_t  dy;
    int64_t  ts_wall_ns;
} __packed;
```

### EVT_TOUCH (0x9013) — 28 bytes

```c
struct drawfs_evt_touch {
    uint32_t surface_id;
    uint32_t contact;     /* contact slot */
    uint32_t phase;       /* 0=down 1=move 2=up */
    int32_t  x;
    int32_t  y;
    int64_t  ts_wall_ns;
} __packed;
```

---

## Wire format

Events arrive on the application fd wrapped in the standard drawfs frame:

  [ frame_hdr (16 bytes) ][ msg_hdr (16 bytes) ][ event_payload ]

msg_hdr.msg_type is the DRAWFS_EVT_* value. msg_hdr.msg_id is 0 for
injected events (not associated with a client request).

---

## Backpressure

Event delivery uses the same backpressure mechanism as EVT_SURFACE_PRESENTED:
the per-session evq_bytes counter is checked against hw.drawfs.max_evq_bytes
(default 8192 bytes, tunable via sysctl). If the queue is full, the injection
ioctl returns ENOSPC and the bridge daemon must drop or buffer the event.

---

## Security

Only processes with read-write access to /dev/draw can call
DRAWFSGIOC_INJECT_INPUT. By default this is uid 0 only.
Applications cannot distinguish injected events from hardware events;
the bridge daemon is a trusted component.
