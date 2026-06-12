# 0006 inputfs USB Device Ownership and Enumeration Strategy (Stage B.2)

## Status

Superseded by ADR 0007 (hidbus attachment).

Investigation of the live system revealed that this ADR was built
on a reading of legacy drivers (`ukbd`, `ums`) that are not loaded
on modern FreeBSD 15. The correct architecture is
hidbus-level attachment with HID TLC matching, specified in ADR
0007. This ADR is retained for the decision-making record.

## Context

Stage B.2 requires `inputfs` to observe USB device attachment and
begin enumerating input-capable devices (keyboards, mice, etc.).

FreeBSD's USB subsystem is built around the `newbus` driver model.
Devices are claimed by a single driver based on probe/attach
matching. Existing drivers such as `ukbd` (USB keyboard) and `ums`
(USB mouse) already match and attach to HID-class devices.

This creates a structural constraint:

* If `ukbd`/`ums` attach to a device, `inputfs` cannot observe or
  consume its input.
* Mechanisms such as `/dev/uhid*` only expose devices **not
  claimed** by specialized drivers.
* Passive notification mechanisms (USB bus events) provide
  attach/detach visibility but **not input streams**.

Therefore, there is no viable architecture in which `inputfs`
passively observes all relevant input devices while `ukbd`/`ums`
remain active.

## Decision

`inputfs` will act as the **owning driver** for USB HID input
devices.

Specifically:

* `inputfs` registers as a USB driver using
  `DRIVER_MODULE(inputfs, uhub, ...)`
* It probes for USB HID-class devices (initially keyboards and
  mice)
* It attaches directly to those devices and becomes their sole
  consumer

`ukbd` and `ums` are treated as **mutually exclusive** with
`inputfs`.

## System Model

This introduces an explicit system-level mode distinction:

### Base FreeBSD Mode

* `ukbd`, `ums`, and console input stack are active
* UTF components are not loaded

### UTF Mode

* `inputfs` and `drawfs` are active
* `ukbd`, `ums`, and console input are absent or inactive
* Input and display are fully owned by UTF subsystems

Switching to UTF mode is a **system configuration decision**, not
a runtime coexistence scenario.

## Rationale

This approach:

* Aligns with FreeBSD's driver ownership model (single consumer
  per device)
* Avoids fragile or undefined behavior from driver contention
* Ensures `inputfs` has complete, reliable access to input streams
* Matches UTF's architectural principle: no external code in the
  guarantee path

Alternative approaches were rejected:

* `/dev/uhid*` access: only exposes unclaimed devices
* USB event subscription without ownership: insufficient for input
  handling
* Probe-score competition with `ukbd`/`ums`: brittle and
  non-deterministic

## Stage B.2 Scope

Stage B.2 does **not** implement full input handling.

It establishes:

1. Driver registration with the USB subsystem
2. Successful probe/attach for at least one HID device
3. Observable confirmation via kernel log output

### Success Criteria

When a USB keyboard or mouse is connected:

* `inputfs`'s `probe` and `attach` methods are invoked
* A log line is emitted, e.g.:

  ```
  inputfs: attached HID device (vendor=0xXXXX, product=0xYYYY)
  ```

No report parsing or event delivery is required at this stage.

## Implementation Plan (Next Session)

1. Create minimal USB driver skeleton:

   * `device_probe`
   * `device_attach`
   * `device_detach`

2. Register driver:

   ```
   DRIVER_MODULE(inputfs, uhub, inputfs_driver, inputfs_devclass, 0, 0);
   ```

3. Implement probe logic:

   * Match USB HID class devices
   * Narrow to boot protocol devices (keyboard/mouse) if needed

4. Implement attach logic:

   * Retrieve device descriptor information
   * Emit structured log message

5. Test strategy:

   * Ensure `ukbd` and `ums` are not loaded
   * Load `inputfs` module
   * Connect USB HID device
   * Verify attach log output

## Consequences

### Positive

* Clear ownership model
* Deterministic behavior
* Clean foundation for later input processing stages

### Negative

* Breaks compatibility with FreeBSD console input while active
* Requires controlled environment for testing and use

## Open Questions (Deferred)

* Exact HID matching strategy (class vs protocol vs report
  descriptor)
* Handling composite devices
* Integration with non-USB input sources
* Transition mechanism between Base and UTF modes

## Notes

This decision is foundational. All subsequent input handling in
UTF assumes that `inputfs` has direct ownership of input devices.
