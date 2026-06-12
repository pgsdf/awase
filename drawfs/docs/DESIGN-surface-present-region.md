# DRAWFS_REQ_SURFACE_PRESENT_REGION — Design

**Status**: Design (B3.1). Not yet implemented.
**Supersedes**: No existing spec — this is new wire protocol.
**Required before**: B3.2 (regenerate headers), B3.3 (swap path
implementation), B3.4 (DRM path), B3.5 (semadraw emitter).

This document specifies a new drawfs request for presenting a surface
with explicit damage rectangles. It accompanies (does not replace) the
existing `DRAWFS_REQ_SURFACE_PRESENT` request.

---

## Motivation

The existing `DRAWFS_REQ_SURFACE_PRESENT` (0x0022) always implies a
full-surface present. Both drawfs backends can do better when the
client knows only a small region has actually changed:

- **Swap backend** emits a `SURFACE_PRESENTED` event per present. With
  dense updates on small dirty regions (think a blinking cursor in a
  terminal), most of the event payload is wasted — the consumer
  already has the surface mapped and only needs to re-read the dirty
  bytes. A rect list lets the consumer re-read only what changed, and
  lets the server coalesce redundant events more aggressively.
- **DRM backend** can forward the rects to `drmModeDirtyFB(2)` on
  hardware that supports it, avoiding a full-framebuffer refresh on
  every flip. On hardware without the ioctl, the rect list is
  informational and the backend falls back to a full present — the
  wire format must support that gracefully.

The compositor (`semadrawd`) already tracks damage rectangles
internally. Today, it discards that information at the drawfs boundary.
B3.5 will plumb it through.

---

## Design alternatives considered

### A. New opcode  `DRAWFS_REQ_SURFACE_PRESENT_REGION = 0x0023` **← chosen**

A second request type that carries a rect list in a variable-length
payload. The existing `SURFACE_PRESENT` remains unchanged — fixed-size
struct, fixed wire bytes, no binary-compatibility risk.

### B. Extend existing opcode via the reserved `flags` field

`drawfs_req_surface_present.flags` is already documented as reserved
for future damage support. Under this alternative, a
`DRAWFS_PRESENT_FLAG_HAS_RECTS` bit would be set and rect data
appended after the existing struct.

### Why A, not B

1. **Fixed-size invariant.** The existing `drawfs_req_surface_present`
   struct is `__packed` and used by clients as a plain C struct with
   compile-time `sizeof`. Variable-length bodies would require every
   receiver to branch on the flag before trusting the size, and every
   current client struct use would become unsafe.
2. **Reserved flags are still useful.** There are other single-bit
   extensions worth preserving capacity for: explicit vsync requests,
   priority hints, skip-if-superseded semantics. Burning the first
   flag bit on "has rects after this struct" would both complicate
   parsing and squat on namespace that costs nothing to preserve.
3. **Separate dispatch.** On the server side, a distinct opcode gives
   a cleaner case split. The rect-parsing code path is naturally
   isolated from the hot path of fixed-size full presents.

The same reasoning produces a second event,
`DRAWFS_EVT_SURFACE_PRESENTED_REGION = 0x9003`, rather than extending
the existing `EVT_SURFACE_PRESENTED` payload.

---

## Opcode assignments

All values are proposed for inclusion in
`shared/protocol_constants.json` under `drawfs_protocol.message_types`.

| Symbol                                          | Value    | Kind    |
|-------------------------------------------------|----------|---------|
| `DRAWFS_REQ_SURFACE_PRESENT_REGION`             | `0x0023` | request |
| `DRAWFS_RPL_SURFACE_PRESENT_REGION`             | `0x8023` | reply   |
| `DRAWFS_EVT_SURFACE_PRESENTED_REGION`           | `0x9003` | event   |

`0x0023` is the next sequential slot in the surface-ops cluster
(`CREATE=0x0020`, `DESTROY=0x0021`, `PRESENT=0x0022`). `0x8023` follows
the reply convention `request | 0x8000`. `0x9003` is the next free slot
in the event range; `0x9002` is `EVT_SURFACE_PRESENTED`.

---

## Wire format

All multi-byte fields are little-endian. Alignment is 4 bytes (drawfs
protocol convention). Structs are `__packed` to avoid compiler padding.

### Shared rect type

A single 16-byte rectangle structure used by the request and the event.

```c
struct drawfs_rect {
    int32_t  x;          /* top-left x in surface-local coordinates */
    int32_t  y;          /* top-left y in surface-local coordinates */
    uint32_t width;      /* width in pixels; must be >= 1            */
    uint32_t height;     /* height in pixels; must be >= 1           */
} __packed;
/* Size: 16 bytes. Natural alignment: 4. */
```

Signed `x` and `y` match existing drawfs coordinate conventions and
allow negative values for clients that use off-surface coordinate
systems (the server clamps; see "Semantics" below). `width` and
`height` are unsigned and must be non-zero — a zero-dimension rect is
a protocol violation, not a no-op.

### Request: `DRAWFS_REQ_SURFACE_PRESENT_REGION` (0x0023)

```c
struct drawfs_req_surface_present_region {
    uint32_t surface_id;
    uint32_t flags;                   /* reserved, must be 0        */
    uint64_t cookie;                  /* opaque, echoed in reply    */
    uint32_t rect_count;              /* number of rects that follow */
    uint32_t _reserved;               /* must be 0; alignment pad   */
    /* struct drawfs_rect rects[rect_count] follows immediately */
} __packed;
/* Fixed header size: 24 bytes.
 * Total payload size: 24 + 16 * rect_count bytes. */
```

`rect_count` is bounded:

- `rect_count == 0` is a protocol violation (`ERR_INVALID_ARG`). A
  zero-rect present is meaningless — callers wanting a full present
  use `SURFACE_PRESENT` instead.
- `rect_count > DRAWFS_MAX_PRESENT_RECTS` (defined as **16**) is a
  protocol violation (`ERR_OVERFLOW`). Sixteen is the working cap;
  see "Capacity choice" below.

The `flags` field mirrors the one in `SURFACE_PRESENT` and is reserved
for the same future uses. Current clients set it to zero; servers
reject any non-zero value with `ERR_UNSUPPORTED_CAP` until specific
bits are defined.

### Reply: `DRAWFS_RPL_SURFACE_PRESENT_REGION` (0x8023)

Identical in shape to `drawfs_rpl_surface_present`. The reply is
symmetric regardless of whether the original request was a full or
regional present.

```c
struct drawfs_rpl_surface_present_region {
    int32_t  status;     /* 0 = success, else drawfs_err_code   */
    uint32_t surface_id;
    uint64_t cookie;     /* echoed from request                 */
} __packed;
/* Size: 16 bytes. */
```

Deliberately no rect list in the reply. The reply acknowledges that
the server accepted the request; the rects are the *client's*
statement of what changed. Echoing them back would consume bandwidth
without adding information.

### Event: `DRAWFS_EVT_SURFACE_PRESENTED_REGION` (0x9003)

```c
struct drawfs_evt_surface_presented_region {
    uint32_t surface_id;
    uint32_t rect_count;           /* number of rects emitted below    */
    uint64_t cookie;               /* echoed from request              */
    /* struct drawfs_rect rects[rect_count] follows immediately */
} __packed;
/* Fixed header size: 16 bytes.
 * Total event size: 16 + 16 * rect_count bytes. */
```

`rect_count` in the event **may differ from the request's
rect_count**. The server is permitted to coalesce adjacent or
overlapping rects before emitting, and must do so when:

- Total rects exceed `DRAWFS_MAX_PRESENT_RECTS` after merging with
  any pending coalesced events (never true on a single request — the
  request is already capped — but possible when the server has
  batched several requests).
- The union of emitted rects covers ≥ 75% of the surface area, in
  which case the server SHOULD emit a single rect covering the
  surface bounds. The 75% threshold is a tunable
  (`hw.drawfs.region_coalesce_threshold`, default 75) to allow
  site-specific tuning; it is not a wire-protocol detail.

Servers MAY emit `EVT_SURFACE_PRESENTED_REGION` even for requests
made via the old `SURFACE_PRESENT` opcode, with `rect_count=1` and
a single rect covering the full surface. Clients MUST be prepared to
receive either event form. This gives servers freedom to standardize
on the richer event type internally.

### Capacity choice: `DRAWFS_MAX_PRESENT_RECTS = 16`

Sixteen rects × 16 bytes per rect = 256 bytes of rect payload per
request, plus the 24-byte header = 280 bytes. That fits comfortably
under `DRAWFS_MAX_MSG_BYTES` and well under `DRAWFS_MAX_FRAME_BYTES`.

The compositor's damage tracker is the upstream source of truth; it
already coalesces aggressively because it has always had a small
hardcoded limit internally. Sixteen is sufficient for every realistic
workload — even a text editor scrolling rapidly typically produces 1-3
dirty bands per frame. Clients that somehow accumulate more than 16
separable dirty regions should coalesce to 16 or fall back to
`SURFACE_PRESENT` (full).

The cap is a protocol-level value, not a sysctl, because changing it
is a wire-format change. If it ever needs raising, that's a new
opcode (or a feature-negotiated extension via HELLO capabilities).

---

## Semantics

### Coordinate clamping

Rects whose `(x, y, width, height)` fall partly or wholly outside the
surface bounds are **clamped to the surface**, not rejected. A rect
entirely outside the surface is dropped (not an error). This lets
clients emit rects in a coordinate system that may not exactly match
the surface's current dimensions (for example, during a resize) without
error-handling boilerplate.

A rect with `width == 0` or `height == 0` **is** an error
(`ERR_INVALID_ARG`). It would be a no-op after clamping, but it
indicates a client bug upstream, and silently accepting it hides real
problems.

### Relationship to `SURFACE_PRESENT`

The two opcodes are functionally equivalent in the default swap
backend when rect_count == 1 and the rect covers the full surface.
Acceptance criterion B3.3.1 enforces this: a region present with
N=1 full-surface rect must produce the same pixel state and the same
event semantics as a `SURFACE_PRESENT`.

Clients are free to mix: a `CREATE_SURFACE` followed by
`SURFACE_PRESENT` followed by `SURFACE_PRESENT_REGION` is valid. The
server holds no state that distinguishes "this surface was last
presented via the regional opcode." Each request is independent.

### Interaction with `hw.drawfs.backend`

- `swap` (default): the server accepts rects, validates and clamps,
  then emits a `SURFACE_PRESENTED_REGION` event. No change in pixel
  memory behaviour — the region information is metadata.
- `drm` (opt-in): the server calls `drmModeDirtyFB(2)` with the
  rect list if the kernel DRM driver supports it. If the ioctl is
  unavailable, the server performs a full present and still emits a
  `SURFACE_PRESENTED_REGION` event with the same rects — the event
  form reflects the *request*, not what the backend physically did.

### Event coalescing

The existing `hw.drawfs.coalesce_events` sysctl (already present, on by
default) governs whether rapid repeat `SURFACE_PRESENTED` events on the
same surface are folded into one. For regional presents the same switch
applies, with this behavioural refinement: two region events are
coalesced into one when (a) they target the same surface, (b) their
rect count totals ≤ `DRAWFS_MAX_PRESENT_RECTS`, and (c) the client has
not consumed the first event yet. Otherwise both are emitted. The
cookie of the **latest** coalesced request wins; earlier cookies are
dropped. Clients that depend on every cookie being echoed back must
disable coalescing.

---

## Error conditions

All errors use the existing `drawfs_err_code` enum; no new codes are
introduced.

| Condition                                         | Error                      |
|---------------------------------------------------|----------------------------|
| `surface_id` unknown to this session              | `ERR_NOT_FOUND` (6)        |
| `rect_count == 0`                                 | `ERR_INVALID_ARG` (11)     |
| `rect_count > DRAWFS_MAX_PRESENT_RECTS`           | `ERR_OVERFLOW` (12)        |
| Any `rect.width == 0` or `rect.height == 0`       | `ERR_INVALID_ARG` (11)     |
| `flags` contains any non-zero bit                 | `ERR_UNSUPPORTED_CAP` (4)  |
| `_reserved` is non-zero                           | `ERR_INVALID_MSG` (2)      |
| Message body shorter than declared `rect_count`   | `ERR_INVALID_FRAME` (1)    |
| Session event queue full                          | `ERR_BUSY` (7)             |

The error is returned via `drawfs_rpl_surface_present_region.status`
— a non-zero `status` means the request was rejected and no event
will be emitted.

---

## Backward compatibility

This is a purely additive change. Existing wire traffic is unaffected:

- `DRAWFS_REQ_SURFACE_PRESENT` (0x0022) is unchanged — same struct,
  same size, same reply shape, same event.
- No existing fields are repurposed. The `flags` field in the old
  request retains its "reserved, must be 0" semantics.
- Clients that never emit `SURFACE_PRESENT_REGION` see no difference.
- Servers that don't support `SURFACE_PRESENT_REGION` reply with
  `ERR_UNSUPPORTED_CAP` (4) from the generic error handler — no
  special-case code needed on the client.

Capability negotiation via `HELLO` is **not** required for this
addition. Clients that want to know ahead of time whether the server
supports the new opcode can issue a `SURFACE_PRESENT_REGION` with a
single full-surface rect to a throwaway surface and check for
`ERR_UNSUPPORTED_CAP`. That's heavier than an explicit capability bit,
so if capability negotiation is added in the future, retroactively
including `PRESENT_REGION` in the capability set is trivial.

---

## Non-goals

These are explicitly out of scope for this spec and will not be
accommodated:

1. **Sub-rectangle damage at finer granularity than the compositor
   tracks.** The compositor's internal damage tracking is the upstream
   source of truth. Drawfs is a pass-through for that information.
2. **Triple-buffering or front/back buffer management.** Present
   semantics remain immediate — rects describe *what changed*, not a
   buffer swap.
3. **Lossless damage across HELLO renegotiations.** If a client
   disconnects and reconnects, the server does not replay pending
   region events. This matches existing `SURFACE_PRESENT` behaviour.
4. **Rect-aware compositor scheduling.** Whether semadrawd uses the
   rect information to reduce its own compositor work is a semadraw
   concern, not a drawfs one. The drawfs wire format does not dictate.

---

## Open questions

These are items where the spec is unambiguous but the choice was not
forced by an existing constraint, and feedback before implementation
could change them:

1. **Should the event echo the cookie?** Current spec: yes, matching
   existing `SURFACE_PRESENTED`. Alternative: drop it from the event
   and require clients to correlate via `surface_id` + ordering. The
   cookie costs 8 bytes per event. I've kept it for parity; flag if
   you want it removed.

2. **Should rect clamping produce a warning event?** Current spec:
   silent clamp. Alternative: emit a lightweight warning event so
   clients can detect "my damage coordinates are drifting out of
   bounds." I think silent is right — the cost of a debug-only event
   type isn't worth the complexity — but flag if you disagree.

3. **Should `_reserved` in the request be checked strictly?** Current
   spec: yes (`ERR_INVALID_MSG` on non-zero). Alternative: ignored
   (as some other protocols do). Strict checking catches client bugs
   early and costs the server one comparison. Keeping it strict.

---

## Implementation impact summary

When this spec moves to B3.2–B3.5, these files change:

- `shared/protocol_constants.json` — add the three opcode entries.
- `shared/tools/gen_constants.py` — no changes (generator is
  structural, consumes whatever is in the JSON).
- `drawfs/sys/dev/drawfs/drawfs_proto.h` — regenerated from JSON;
  hand-written struct definitions added for the three new message
  types and the shared `drawfs_rect`.
- `drawfs/sys/dev/drawfs/drawfs_frame.c` — new validator for the
  request, coalescing logic for the event.
- `drawfs/sys/dev/drawfs/drawfs.c` — new dispatch branch on
  `DRAWFS_REQ_SURFACE_PRESENT_REGION`; minor addition to the event
  emission path.
- `drawfs/sys/dev/drawfs/drawfs_drm.c` — `drmModeDirtyFB` call when
  the ioctl is present; no-op-to-full-present fallback otherwise.
- `drawfs/tests/` — new `test_surface_present_region.py` exercising
  the error table, coalescing, and the N=1-full-surface equivalence
  invariant.
- `semadraw/src/backend/drawfs.zig` — new emitter path that consumes
  the compositor's damage tracker output and issues region presents.

No semadraw IPC or SDCS changes. This is drawfs-local.

---

## Acceptance criteria (for the full B3 chain, restated here)

Carried forward from the root backlog so implementation can target
them without cross-referencing.

1. A full-surface present (current `SURFACE_PRESENT` wire bytes) must
   remain bit-identical — zero regression for clients that never
   emit the new opcode.
2. A `SURFACE_PRESENT_REGION` with `rect_count=1` covering the full
   surface bounds must produce pixel-identical output and semantically
   equivalent event behaviour to a `SURFACE_PRESENT`.
3. The error table above must be enforced exactly — no silent
   acceptance of malformed requests.
4. On a DRM-backed build without `drmModeDirtyFB` support, the server
   must fall back to a full present with no visible error, while
   still emitting the regional event.
