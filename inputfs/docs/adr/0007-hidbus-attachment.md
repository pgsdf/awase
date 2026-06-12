# 0007 inputfs hidbus Attachment and HID TLC Matching

## Status

Proposed

Supersedes `inputfs/docs/adr/0006-usb-device-ownership.md`.

## Context

ADR 0006 committed inputfs to attach as a USB driver on the `uhub`
bus, matching devices by USB interface class (HID), subclass (boot),
and protocol (keyboard or mouse). This was wrong. Investigation
of the running FreeBSD 15.0-RELEASE-p2 system revealed that
the FreeBSD HID subsystem has a two-layer architecture that ADR
0006 did not account for:

```
Transport layer:   uhub  -> usbhid       (USB-to-HID transport)
HID layer:                   hidbus  -> hms, hkbd, hgame, hcons,
                                        hsctrl, utouch, hidmap, etc.
```

Every USB HID-class device is claimed by `usbhid` at the USB layer,
which then presents the device on a `hidbus`. Specialized drivers
attach at `hidbus`, not at `uhub`. The Stage B.2 code that ADR 0006
produced loads cleanly but never receives probe calls, because
`usbhid` has already claimed every HID-class device by the time a
`uhub`-level driver gets a chance.

ADR 0006 was drafted after reading `ukbd.c` and `ums.c`, which are
legacy drivers that still exist in source but are no longer loaded
on modern FreeBSD systems. The current adversaries are `hms`
(modern HID mouse), `hkbd` (modern HID keyboard), `hgame`, `hcons`,
`hsctrl`, and `utouch`, all attached at `hidbus`. `ukbd` and `ums`
are not relevant to the current system.

This ADR corrects the architecture and supersedes ADR 0006
completely. The System Model concept from ADR 0006 is preserved
with an updated list of displaced drivers.

## Decision

1. inputfs attaches as a `hidbus`-level driver, registered via
   `DRIVER_MODULE(inputfs, hidbus, ...)`. The USB/Bluetooth/I2C HID
   transport layer is left alone; inputfs operates at the level
   where the device has already been reduced to HID-layer semantics.

2. Device matching uses HID Top-Level Collections (TLCs) via the
   `hid_device_id` structure and `HID_TLC(page, usage)` macro. The
   v1 match table matches:
   - Generic Desktop / Keyboard (`HUP_GENERIC_DESKTOP`, `HUG_KEYBOARD`)
   - Generic Desktop / Mouse (`HUP_GENERIC_DESKTOP`, `HUG_MOUSE`)
   - Generic Desktop / Pointer (`HUP_GENERIC_DESKTOP`, `HUG_POINTER`)

   Additional TLCs (gamepad, consumer controls, system controls,
   touchpad, digitizer) are deferred to later Stage B sub-items
   matching the inputfs role taxonomy from ADR 0004.

3. inputfs does **not** use `hidmap`. `hidmap` is the framework
   that bridges HID events to `evdev`. Since UTF's discipline
   excludes evdev, inputfs must consume HID reports directly via
   `hidbus_set_intr(dev, handler, context)`. This keeps report
   parsing inside inputfs where it belongs rather than routing
   through a bridge that targets the wrong consumer.

4. inputfs is mutually exclusive with the full set of hidbus
   drivers it displaces. UTF Mode assumes the following are absent
   at boot:
   - `hms` (HID mouse)
   - `hkbd` (HID keyboard)
   - `hgame` (HID gamepad)
   - `hcons` (HID consumer controls)
   - `hsctrl` (HID system controls)
   - `utouch` (USB touchscreen)
   - `hpen` (HID digitizer pen, if present)
   - `hidmap` (not strictly required, but consumes resources inputfs
     does not need)

   The `usbhid` transport driver and `hidbus` bus driver are
   retained; they are infrastructure, not policy. inputfs
   cooperates with them rather than displacing them.

5. inputfs returns `BUS_PROBE_DEFAULT` from its probe function.
   This outscores `hms` and `hkbd` (which return `BUS_PROBE_GENERIC`)
   when both are loaded, but under UTF Mode the point is moot
   because the competing drivers are absent. The probe-score choice
   exists to handle transitional configurations.

## System Model (revised)

The Base FreeBSD Mode vs UTF Mode distinction from ADR 0006 is
retained. The revised driver lists:

### Base FreeBSD Mode

- `usbhid`, `hidbus` loaded (transport and bus infrastructure)
- `hms`, `hkbd`, `hgame`, `hcons`, `hsctrl`, `utouch`, `hpen`
  loaded as consumers
- `hidmap` loaded (HID-to-evdev bridge)
- `evdev` loaded
- Console input functional through the above stack
- UTF components not loaded

### UTF Mode

- `usbhid`, `hidbus` loaded (transport and bus, unchanged)
- `hms`, `hkbd`, `hgame`, `hcons`, `hsctrl`, `utouch`, `hpen`
  absent
- `hidmap` absent
- `evdev` absent
- inputfs loaded as the sole `hidbus`-level consumer
- drawfs loaded
- Console input handled by inputfs (once later Stage B work
  implements it)

Switching between modes is a boot-configuration decision. Runtime
transition between modes is out of scope.

## Rationale

This architecture:

- Matches the actual FreeBSD 15 HID stack.
- Is transport-agnostic: USB, Bluetooth, and I2C HID devices all
  reach `hidbus` the same way, so inputfs automatically handles
  all three without transport-specific code. This is an
  improvement over ADR 0006, which was USB-only.
- Matches on HID semantic identity (TLCs) rather than USB protocol,
  which is the natural abstraction for describing "what kind of
  input device is this."
- Bypasses `hidmap` because hidmap's purpose is to feed evdev.
  inputfs is not an evdev consumer; it is an evdev replacement.
- Preserves ADR 0006's System Model framing, which remains correct
  at the conceptual level.

Alternative approaches rejected:

- **Keep ADR 0006's `uhub` attachment**: would fail to claim any
  devices because `usbhid` has already claimed them at that layer.
  This is what the Stage B.2 code produces today, which is why
  this ADR exists.
- **Attach at `usbus`**: would conflict with `usbhid`, which
  already owns that layer. Attaching below `usbhid` means
  duplicating what `usbhid` does.
- **Use hidmap as a framework**: would require inputfs to produce
  evdev events, which contradicts UTF's discipline.
- **Replace `usbhid`**: unnecessary. `usbhid` is transport
  infrastructure, not input policy. UTF gains nothing by owning it.

## Consequences

### Positive

- inputfs handles USB, Bluetooth, and I2C HID devices uniformly,
  with no transport-specific code paths.
- inputfs matches devices by semantic type (HID TLC) rather than
  by transport protocol, which aligns with the role taxonomy in
  ADR 0004.
- inputfs never sees evdev as a dependency, direct or indirect.
  hidmap is absent, evdev is absent, and inputfs consumes HID
  reports through the `hidbus_set_intr` callback directly.
- The `usbhid` and `hidbus` layers remain FreeBSD's, not UTF's.
  UTF does not carry the maintenance burden of reimplementing USB
  HID transport.

### Negative

- The set of displaced drivers is larger than ADR 0006 named:
  seven drivers and the `hidmap` framework, rather than just
  `ukbd` and `ums`. UTF Mode requires all of them to be absent.
- `hidbus` and `usbhid` are accepted dependencies under UTF's
  architectural discipline. They are not UTF-authored code and
  they are in the guarantee path. This must be recorded in
  `docs/UTF_ARCHITECTURAL_DISCIPLINE.md` under "Accepted
  dependencies." The alternative (reimplementing USB HID transport
  inside inputfs) is substantially larger work than UTF's scope
  permits in the foreseeable future.
- The probe collision under mixed configurations (inputfs loaded
  alongside hms or hkbd) is real. Probe score arbitration picks
  one driver per device. Under UTF Mode the competing drivers are
  absent, so the question does not arise in practice.

## Stage B.2 Scope (revised)

Stage B.2 establishes:

1. inputfs registration as a `hidbus` driver via
   `DRIVER_MODULE(inputfs, hidbus, ...)`.
2. HID TLC matching for keyboard, mouse, and pointer.
3. Successful probe and attach for at least one HID device of
   each matched TLC.
4. Kernel log output on attach and detach, identifying the device
   by vendor and product ID from `hid_get_device_info`.

### Success Criteria

With `hms`, `hkbd`, `hgame`, `hcons`, `hsctrl` unloaded and
inputfs loaded, attaching a USB HID keyboard or mouse produces
a dmesg line along the lines of:

```
inputfs0: <HID keyboard on hidbus> (vendor=0xXXXX, product=0xYYYY)
```

No HID report parsing, no event publication, no shared-memory
regions, and no ioctls. Those remain Stage B.3 onwards.

## Implementation Plan

1. Rewrite `inputfs.c` to:
   - Include `<dev/hid/hid.h>` and `<dev/hid/hidbus.h>`.
   - Declare a `hid_device_id` match table with three entries
     using the `HID_TLC(HUP_GENERIC_DESKTOP, X)` macro for `HUG_KEYBOARD`,
     `HUG_MOUSE`, and `HUG_POINTER`.
   - Implement `probe` using `HIDBUS_LOOKUP_ID(dev, inputfs_devs)` or
     `HIDBUS_LOOKUP_DRIVER_INFO(dev, inputfs_devs)`.
   - Implement `attach` to retrieve device info via
     `hid_get_device_info(dev)` and log vendor/product.
   - Implement `detach` symmetrically.
   - Register via `DRIVER_MODULE(inputfs, hidbus, inputfs_driver,
     inputfs_modevent, NULL)`.
   - Declare `MODULE_DEPEND(inputfs, hid, 1, 1, 1)` and
     `MODULE_DEPEND(inputfs, hidbus, 1, 1, 1)`.
   - Declare `HID_PNP_INFO(inputfs_devs)` for devd auto-loading.

2. Update `Makefile`:
   - Drop `opt_usb.h` and `usb_if.h` from SRCS.
   - Retain `bus_if.h` and `device_if.h`.
   - No new SRCS entries needed for hidbus; `hid.h` and `hidbus.h`
     are ordinary headers installed under `/usr/src/sys/dev/hid/`.

3. Test procedure on `vic@test-machine`:
   - `kldunload hms hkbd hgame hcons hsctrl utouch` (any that are loaded).
   - `kldload inputfs`.
   - Plug in a USB keyboard or mouse, or replug existing devices.
   - `dmesg | tail -20` to verify the attach log line.
   - `kldunload inputfs` to verify clean detach.

4. Update `docs/UTF_ARCHITECTURAL_DISCIPLINE.md` to record
   `usbhid`, `hidbus`, and `hid` as accepted dependencies in the
   guarantee path. This is a separate commit, not part of the B.2
   code commit.

## Notes

This ADR treats the B.2 code already on origin (USB-attached
inputfs) as a learning artifact rather than a failure. It loads
and unloads cleanly, which validated the module event handler and
the build infrastructure. The architectural correction is the real
Stage B.2 decision; the code revision is its implementation.

Superseding rather than revising ADR 0006 preserves the
decision-making record. Future readers can see both the initial
design (based on legacy-driver reading) and the corrected one
(based on the live system). The forward-only history policy makes
this transparent.

The hidbus layer is documented in `sys/dev/hid/hidbus.h`. The
macros and types this ADR commits to using (`HID_TLC`,
`HIDBUS_LOOKUP_ID`, `hid_get_device_info`, `hidbus_set_intr`) are
stable public API per that header.

A future Stage B sub-item will add TLCs for the remaining roles in
ADR 0004:

- Pen: `HID_TLC(HUP_DIGITIZERS, HUD_PEN)` and related.
- Touch: digitizer TLCs (touchscreen, touchpad, multitouch).
- Lighting: lighting-specific TLCs per the USB LED page.

These are not part of Stage B.2 but are expected extensions of the
match table.
