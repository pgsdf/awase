# 0009 Interrupt Handler Registration and Raw Report Logging (Stage B.4)

## Status

Proposed

## Context

Stage B.3 (ADR 0008) established descriptor fetch and walk. inputfs
attaches to HID devices, fetches the report descriptor via
`hid_get_report_descr`, walks it to count items and maximum collection
depth, and logs the results. No reports flow: `hidbus_set_intr` has not
been called, so inputfs receives nothing from the device.

Stage B.4 closes that gap. It registers an interrupt callback via
`hidbus_set_intr` so hidbus delivers each incoming HID report to
inputfs. The callback copies the report bytes into a per-device buffer
and logs a hex dump to dmesg. No userspace event publication happens
until Stage C.

ADR 0008 § Notes states:

> Stage B.4 will add `hidbus_set_intr(dev, handler, context)` to
> register a report-delivery callback, allocate a buffer sized per
> `hid_report_size_max`, and log incoming reports as hex dumps to
> dmesg.

This ADR fulfills that commitment.

## Decision

### 1. Buffer allocation

`hid_report_size_max(sc->sc_rdesc, sc->sc_rdesc_len, hid_input,
&sc->sc_report_id)` is called during `inputfs_attach` immediately
after the B.3 descriptor walk. It returns the byte count of the
largest input report for this device and populates `sc_report_id`
with the associated report ID (zero if the device uses no report IDs).

If the returned size is zero or negative, no buffer is allocated and
`hidbus_set_intr` is not called. The device attaches cleanly but
receives no reports; this is logged as an informational message.

If the size is positive, `malloc(size, M_INPUTFS, M_WAITOK | M_ZERO)`
allocates the buffer. `MALLOC_DEFINE(M_INPUTFS, ...)` is added at file
scope.

The softc gains three new fields:

```c
uint8_t    *sc_ibuf;       /* interrupt report buffer              */
hid_size_t  sc_ibuf_size;  /* max input report size in bytes       */
uint8_t     sc_report_id;  /* report ID from hid_report_size_max   */
```

### 2. Interrupt registration

After the buffer is allocated, `hidbus_set_intr(dev, inputfs_intr, sc)`
registers the callback. The interrupt begins firing immediately.
hidbus deregisters the callback automatically on detach; no explicit
deregistration call is needed in `inputfs_detach`.

The callback signature matches `hid_intr_t` from `hid.h`:

```c
typedef void hid_intr_t(void *context, void *data, hid_size_t len);
static void inputfs_intr(void *context, void *data, hid_size_t len);
```

### 3. Interrupt handler

`inputfs_intr` is called from interrupt context. It must not sleep,
block, or call any function that may sleep.

The handler:

1. Returns immediately if `sc->sc_ibuf` is NULL (defensive; should
   not happen if registration succeeded).
2. Clamps `len` to `sc_ibuf_size`. If truncation occurs, logs a
   warning once via `device_printf`.
3. Copies `min(len, sc_ibuf_size)` bytes from `data` into
   `sc_ibuf` using `memcpy`.
4. Formats a hex string from the copied bytes.
5. Logs one `device_printf` line in the format:

```
inputfs0: inputfs: report id=0x01 len=4 data=01 00 00 00
```

The report ID field is `sc_ibuf[0]` (the first byte of the report,
which is the report ID for devices that use report IDs, or the first
data byte for devices that do not). This matches the convention used
in B.3 debugging sessions.

### 4. Locking

Stage B.4 does not introduce mutex locking in the interrupt path.
The handler writes only to `sc_ibuf` (private) and calls
`device_printf` (safe from interrupt context on FreeBSD). `sc_mtx`
is initialized in attach but not acquired in the handler. Stage C
will introduce proper locking when reports are published to shared
memory.

### 5. Detach

`inputfs_detach` frees `sc_ibuf` via `free(sc->sc_ibuf, M_INPUTFS)`
and sets it to NULL before destroying `sc_mtx`. hidbus has already
deregistered the interrupt callback by the time `device_detach`
returns, so no in-flight callback can access the freed buffer.

## Consequences

1. inputfs now receives live HID reports from attached devices.
2. Each report produces one dmesg line, enabling manual verification
   that the interrupt path is functional on real hardware.
3. `M_INPUTFS` malloc type is introduced. The buffer is one allocation
   per attached device, sized to that device's maximum input report.
4. No userspace component is affected. No shared memory is written.
   No ioctls are added. No evdev dependency is introduced.
5. Stage C will build userspace event publication on top of the
   interrupt path established here.

## Stage B.4 Scope

Stage B.4 establishes:

1. `MALLOC_DEFINE(M_INPUTFS, ...)` at file scope.
2. Buffer allocation via `hid_report_size_max` in `inputfs_attach`.
3. `hidbus_set_intr(dev, inputfs_intr, sc)` in `inputfs_attach`.
4. `inputfs_intr` callback: copy and hex-log each report.
5. Buffer free in `inputfs_detach`.

### Success Criteria

With inputfs loaded and hms/hkbd unloaded, and the keyboard or mouse
physically in use (typing or moving):

```
inputfs0: inputfs: report buffer 8 bytes (report_id=0x00), registering interrupt
inputfs0: inputfs: report id=0x00 len=8 data=00 04 00 00 00 00 00 00
inputfs0: inputfs: report id=0x00 len=8 data=00 00 00 00 00 00 00 00
```

The exact byte values depend on the device and the input event. A key
press and release pair should produce two distinct reports. A mouse
move should produce reports with non-zero XY bytes.

`kldunload inputfs` must produce a clean detach with no dmesg warnings
and no panic.

## Implementation Plan

1. Add `MALLOC_DEFINE(M_INPUTFS, "inputfs", "inputfs report buffers")`
   after the `#include` block.
2. Add `sc_ibuf`, `sc_ibuf_size`, `sc_report_id` to
   `struct inputfs_softc`.
3. In `inputfs_attach`, after `inputfs_walk_rdesc`:
   a. Call `hid_report_size_max` to get max input report size.
   b. If size > 0, allocate `sc_ibuf`.
   c. Call `hidbus_set_intr(dev, inputfs_intr, sc)`.
4. Implement `inputfs_intr`.
5. In `inputfs_detach`, free `sc_ibuf` if non-NULL before
   destroying `sc_mtx`.
6. Update `MOD_LOAD` message to say Stage B.4.

## Testing

Test sequence on target (FreeBSD 15):

1. Unload competing drivers if present:
   `sudo kldunload hms hkbd hgame hcons hsctrl utouch 2>/dev/null || true`
2. Build and load: `cd inputfs && make && sudo kldload ./inputfs.ko`
3. Check attach: `dmesg | grep inputfs | tail -10`
   — expect report buffer size and "registering interrupt" lines.
4. Generate input: type on the keyboard and move the mouse.
5. Check reports: `dmesg | grep "inputfs: report" | tail -10`
   — expect hex-dump lines corresponding to the input events.
6. Unload: `sudo kldunload inputfs`
   — expect "detached" lines, no panic, no dmesg warnings.

## Notes

`hidbus_set_intr` takes `hid_intr_t *` (a function type, not a
function-pointer type). The `inputfs_intr` declaration must match
exactly: `static void inputfs_intr(void *context, void *data,
hid_size_t len)`.

The interrupt fires as soon as `hidbus_set_intr` returns. On a system
where the keyboard is the only input to the console session, the first
report may arrive before `inputfs_attach` has finished logging. This
is benign: the handler checks `sc_ibuf != NULL` before touching it,
and the buffer is fully initialized before `hidbus_set_intr` is called.

`device_printf` from interrupt context is safe on FreeBSD. It uses a
low-level message buffer that does not require scheduler services.
The hex-format loop in the handler is bounded: the `hexbuf` array is
256 bytes, and the loop exits when full or when all bytes are consumed.
