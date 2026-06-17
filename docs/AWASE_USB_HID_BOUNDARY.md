# Awase USB / HID dependency boundary

This document describes the contract Awase expects from FreeBSD's
USB and HID stacks, the specific surface Awase depends on, and the
behaviours Awase would notice if those layers changed. It exists
because Awase declines to own USB and to own the HID transport
layer, and that decision needs to be explicit at the boundary
rather than spread across a dozen ADRs.

## Two layers, one contract

Awase's input substrate (`inputfs`) attaches into FreeBSD's input
hierarchy at one specific layer. Below that layer, Awase accepts the
platform; above it, Awase owns the stack.

```
              Awase owns:    semadrawd, clients (semainputd retired 2026-05-08)
                              ▲
                              │  /var/run/sema/input ring
                              │
             Awase owns:    inputfs.ko (this repository)
                              ▲
                              │  hidbus child attachment
                              │  HID report descriptor parsing
                              │  HID interrupt callbacks
                              │
        Awase accepts:     hidbus, hid, usbhid (FreeBSD)
                              ▲
                              │  USB endpoint I/O
                              │
        Awase accepts:     usb, ehci/xhci/uhci/ohci (FreeBSD)
                              ▲
                              │  PCI bus
                              │
        Awase accepts:     pci, kernel (FreeBSD)
```

The horizontal line is the boundary this document records. Awase
sees `hidbus_get_usage`, `hid_get_item`, `hid_intr_start`. Awase
does not see USB endpoints, USB requests, or USB device
descriptors; those live below the line.

## What Awase requires of the platform

The required-surface enumeration is small. inputfs uses eleven
specific entry points across `<dev/hid/hid.h>` and
`<dev/hid/hidbus.h>`; the surface has been stable across FreeBSD
14 and 15 and corresponds to API patterns FreeBSD treats as
contract.

### From `<dev/hid/hidbus.h>`

| Symbol | Used by | Required behaviour |
|--------|---------|--------------------|
| `HIDBUS_LOOKUP_DRIVER_INFO(dev, table)` | `inputfs_probe` | Match a `hid_device_id` table at probe time; return 0 on hit. |
| `hidbus_set_desc(dev, str)` | `inputfs_probe` | Set the device description visible to `devinfo(8)`. |
| `hidbus_get_usage(dev)` | role classification | Return a 32-bit usage value (`HID_GET_USAGE_PAGE` upper, `HID_GET_USAGE` lower) for the matched TLC. |
| `hidbus_set_intr(dev, handler, arg)` | attach | Register interrupt callback; safe to call at attach time. |

### From `<dev/hid/hid.h>`

| Symbol | Used by | Required behaviour |
|--------|---------|--------------------|
| `hid_get_device_info(dev)` | attach | Return a non-NULL `hid_device_info *` for the device's vendor / product / version. |
| `hid_get_report_descr(dev, &p, &len)` | descriptor fetch | Return the device's report descriptor as a pointer + length; pointer remains valid until detach. |
| `hid_start_parse(rdesc, len, kindset)` | descriptor parse | Return a parser state machine; subsequent `hid_get_item` calls walk the descriptor. |
| `hid_get_item(state, &item)` | descriptor parse | Return >0 with a populated `hid_item` while items remain; return ≤0 when done. |
| `hid_get_data(buf, len, locator)` | report decode | Extract a field by HID locator from a report payload. |
| `hid_intr_start(dev)` | attach finalisation | Begin delivering interrupts to the registered handler. |
| `hid_intr_stop(dev)` | detach | Stop delivering interrupts; safe to call from detach. |

### From the matching protocol

Awase's `inputfs_devs[]` table at the top of `inputfs.c` lists the
TLCs (top-level collections) inputfs claims:

- Generic Desktop / Mouse (0x01 / 0x02)
- Generic Desktop / Keyboard (0x01 / 0x06)
- Generic Desktop / Joystick (0x01 / 0x04)
- Generic Desktop / Game Pad (0x01 / 0x05)
- Generic Desktop / System Control (0x01 / 0x80)
- Consumer (0x0c / *)
- Digitizer (0x0d / *)

inputfs depends on `hidbus` matching its child drivers against
this table. The table is the negotiation surface between inputfs
and hidbus; ADR 0007 covers the design rationale.

## What Awase deliberately does not use

The boundary cuts here, not below. Awase's source tree does not
include any of the following, and the discipline says it should
not:

- **USB endpoint I/O.** `<dev/usb/usb.h>`, `<dev/usb/usbdi.h>`,
  the `usbd_*` family, USB endpoint descriptors, USB transfer
  setup. inputfs does not initiate USB transfers, does not parse
  USB device descriptors, does not implement USB device classes.
  All of that lives in `usbhid` and below.

- **USB controller drivers.** `xhci`, `ehci`, `uhci`, `ohci` are
  accepted as-is. Awase has no opinion on host-controller
  selection or on which USB version the platform supports.

- **Kernel HID report parsing internals.** Awase calls
  `hid_start_parse` / `hid_get_item` and treats the returned
  `hid_item` as a stable struct, but does not look inside the
  parser state machine or implement its own descriptor walker.

- **Bluetooth HID.** inputfs's match table is hidbus-keyed, and
  Bluetooth HID arrives via a different transport
  (`ng_btsocket`, `ubt`); the path is not exercised. Future
  Bluetooth HID support would either reuse the same hidbus
  surface (if Bluetooth-HID-over-hidbus exists in FreeBSD's
  future) or attach via a sibling driver. Out of scope for AD-7.

- **HID-over-I²C.** Currently routed through `iichid` →
  hidbus; inputfs benefits from this transparently because the
  hidbus child surface is the same. Awase does not depend on the
  I²C path being present, only on hidbus producing a child when
  one is. Confirmed working on touchscreen-equipped laptops at
  Stage B.5 verification.

## What changes in the platform would notice us

The contract is most useful for predicting which platform
changes Awase must adapt to and which it can absorb silently.

### Changes that would break inputfs

- **Removing or renaming any of the eleven entry points above.**
  This is breakage at the source level and would surface as
  compile errors. Any of them disappearing in a future FreeBSD
  release requires an inputfs port; the discipline says this is
  acceptable because the surface is small and the work is
  bounded.

- **Changing the hidbus child-device naming convention.**
  inputfs's match table targets specific TLC pairs. If hidbus
  starts matching by interface descriptor rather than TLC, or
  changes the usage encoding format, inputfs's match logic
  needs updating.

- **Changing `hid_item` struct layout (binary).** Awase compiles
  against FreeBSD kernel headers and re-builds per release.
  ABI-level changes to `hid_item` are a recompile event, not a
  port event, but the rebuild is required. A field rename
  (e.g. `hid_item.report_size` → `hid_item.size`) would surface
  as a compile error.

- **Removing the kernel-mode HID parser.** If FreeBSD pushed
  HID descriptor parsing entirely into userland, Awase would need
  its own parser or to ship one alongside inputfs. This is
  hypothetical; no signal of such a change exists.

### Changes that would silently affect inputfs

- **USB host-controller driver bugs causing dropped reports.**
  inputfs sees the symptom (events stop arriving for a device)
  but cannot diagnose below the hidbus boundary. The user-visible
  effect is "input device sometimes loses events"; the hidbus and
  USB layers below would need debugging. Awase's response is to
  log the gap once via the AD-13.2 suppression flag and continue.

- **Power-management transitions losing HID state.** USB HID
  devices reset when the bus suspends and resumes; inputfs sees
  detach + reattach via hidbus. If the platform suspend/resume
  path leaves a device in an inconsistent state (e.g. "attached
  but not delivering reports"), inputfs cannot distinguish that
  from a healthy idle device. Operationally degraded but not a
  bug at the inputfs layer.

- **PNP signature changes in firmware updates.** A device
  firmware update that changes vendor/product IDs or modifies
  the report descriptor causes hidbus to re-probe; inputfs's
  match table determines whether the new descriptor still
  matches a TLC inputfs claims. Most updates preserve the TLC
  layout; a TLC change is a device-side breakage that inputfs
  must adapt to (extending the match table or accepting the
  device under a different role).

### Changes Awase will not notice

- **USB controller swaps within a host-controller family.** If
  a system goes from `ehci` to `xhci` (USB 2 to USB 3), inputfs
  does not care; the hidbus child surface is identical.

- **`usbhid` internal refactoring.** The `usbhid` driver
  translates USB HID reports into hidbus interrupts. Internal
  changes (buffer sizes, locking strategy, error-recovery
  policy) are invisible to inputfs as long as the hidbus
  contract holds.

- **HID device firmware updates that preserve TLC and report
  layout.** The descriptor fetch produces a slightly different
  byte stream but the parsed result is equivalent. inputfs
  re-classifies on attach; nothing else is required.

## What Awase does if the boundary fails

Storage failure has its own document (`AWASE_STORAGE_DEPENDENCY.md`)
and a daemon-side ADR (`AWASE_DAEMON_DEPENDENCY_ABSENCE.md`). The
USB/HID failure modes are smaller and live entirely in the
kernel.

**hidbus probe returns no children**: the device-class drivers
(removed in PGSD per AD-8) are not loaded; inputfs is the only
candidate; if inputfs's match table has no entry for a device's
TLC, the device sits unattached. `dmesg` shows no driver for the
device; `usbconfig` shows the underlying USB device. The user-
visible effect is "this input device doesn't work." Recovery is
extending inputfs's match table.

**`hid_get_report_descr` fails**: inputfs logs the failure once
(AD-13.2 pattern) and detaches. The device remains in the kernel
under no driver; the rest of inputfs continues unaffected.

**`hid_intr_start` returns non-zero**: inputfs detaches the
device; same disposition as descriptor fetch failure. Other
attached devices keep working.

**Interrupt handler called with malformed report**: inputfs's
descriptor-driven decode rejects the report (returns without
publishing). The device stays attached; subsequent reports are
processed normally. The malformed-report path is fuzzed under
AD-9 (HID descriptor and report fuzzing).

**`hidbus` itself unloaded**: inputfs detaches as a byproduct of
hidbus losing its child. The publication ring at
`/var/run/sema/input/events` retains its last contents but no
new events arrive. `kldload inputfs` after `kldload hidbus` works
fine; ordering is the rc.d concern AD-12 addresses for the
daemon side.

## Why this layering matters

Two practical consequences of recording the boundary:

1. **The work to port Awase to a non-FreeBSD platform is bounded
   by this document.** A NetBSD or OpenBSD port of inputfs needs
   either a `hidbus`-equivalent layer on those platforms or a
   re-implementation of the eleven entry points above. Neither
   is small, but both are bounded. The same is true of any
   future major-version FreeBSD that significantly changes the
   HID stack.

2. **Awase's substrate stays on the right side of the
   `accept-fence-replace` decision for USB/HID.** The discipline
   doc says Awase accepts FreeBSD's USB stack and the controller
   drivers; this document confirms that the acceptance is not
   begrudging. The eleven entry points are stable, the contract
   is small, the failure modes are recoverable. There is no
   pressure from the substrate work to start owning USB; a
   future AD item to replace the HID layer would have to argue
   against the analysis here, not in addition to it.

## References

- `docs/AWASE_ARCHITECTURAL_DISCIPLINE.md`, accepted-dependency
  list. The "USB and HID transport" entry references this
  document for the boundary detail.
- `docs/FREEBSD_SUBSYSTEMS.md`, subsystem-by-subsystem
  classification. The "Input subsystem" table covers the
  per-driver disposition; this document covers the contract
  with the layers Awase accepts.
- `docs/AWASE_STORAGE_DEPENDENCY.md`, sibling doc, same shape,
  storage instead of input.
- `docs/AWASE_DAEMON_DEPENDENCY_ABSENCE.md`, daemon-side
  failure-mode policy (Posture 3 degradation).
- `inputfs/docs/adr/0006-usb-device-ownership.md`, design
  rationale for not owning the USB transport layer.
- `inputfs/docs/adr/0007-hidbus-attachment.md`, design
  rationale for hidbus as the attachment surface.
- `inputfs/docs/adr/0008-hid-descriptor-fetch.md`, design
  rationale for the descriptor-fetch sequence.
- `inputfs/docs/adr/0009-interrupt-handler-registration.md`,
  design rationale for the interrupt-handler protocol.
- `inputfs/docs/adr/0011-attachment-layer-review.md`, review
  of whether attaching at hidbus (vs lower) was correct.
- `inputfs/sys/dev/inputfs/inputfs.c`, implementation; uses
  the eleven entry points enumerated above.
- BACKLOG.md AD-7, the work item this document closes.
