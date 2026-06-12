# 0005 Lighting command mechanism

Status: Proposed

## Context

ADR 0004 fixed the initial role taxonomy at five roles: pointer,
keyboard, touch, pen, lighting. Lighting is distinct from the
other four in that it is a consumer direction. Userspace sends
commands to devices (set LED state, set backlight level, set RGB
zone), rather than devices sending events to userspace. ADR 0004
deferred the mechanism for this flow; this ADR decides it.

The decision matters because lighting is the first inbound
channel inputfs will carry from userspace to device. The
mechanism chosen here sets precedent for any future inbound
channel (for example, haptic feedback on pens or game
controllers, if those roles are added later).

Lighting hardware in the field ranges from single status LEDs
(caps lock indicator) to full per-key RGB arrays. The mechanism
must accommodate both the low-capability and high-capability
ends without making the simple case heavy or the complex case
impossible.

## Decision

1. Lighting commands are delivered through an ioctl interface on
   `/dev/inputfs`, not through a shared-memory region and not
   through the event ring. The ioctl is synchronous: the caller
   submits a command and receives a result.

2. The command structure identifies the target device by the
   device identifier published in the state region's device
   inventory. A lighting command with an unknown device id
   returns an error.

3. Three command variants are defined for v1:
   - **set_boolean**: turn an addressable indicator LED on or
     off. Used for caps lock, num lock, scroll lock, and
     equivalent device-level state indicators.
   - **set_brightness**: set a zone's brightness to a value in
     the range `[0, 255]`. Used for single-channel backlights.
     A zone index of zero targets the device's default zone.
   - **set_rgb**: set a zone's colour to a 24-bit RGB value.
     Used for multi-zone lighting and per-key RGB.

4. Devices advertise their lighting capabilities through the
   state region's device inventory. Each device entry carries
   a lighting capability descriptor listing available zones,
   per-zone type (boolean, brightness, RGB), and per-zone
   constraints (number of sub-zones, RGB colour depth if less
   than 24-bit). Clients consult the descriptor before
   submitting commands.

5. Commands that target unsupported capabilities return an
   error without modifying device state. The ioctl does not
   silently ignore or partially-apply commands.

6. Access control follows foundations §7 write-access rules.
   Submitting a lighting command requires the same privilege
   level as event synthesis. No separate lighting-control
   tier exists in v1.

7. Patterns and animations (device-side programs that cycle
   through lighting states over time) are explicitly out of
   scope for v1. Devices that support patterns are usable
   through the three command variants; their pattern engines
   are inaccessible through inputfs until a follow-on ADR
   adds them.

## Consequences

1. The ioctl path is the first non-read surface on
   `/dev/inputfs`. The device node supports read-only mmap for
   state and event regions, kqueue-able poll for real-time
   wakeup, and now ioctl for lighting commands. These surfaces
   are independent and do not share infrastructure beyond the
   file descriptor.

2. The state region's device inventory gains lighting
   capability fields. The state region companion spec (planned
   under AD-1) must define the byte layout for these fields.
   This ADR does not specify that layout; it specifies that the
   fields exist and what they carry.

3. Lighting command frequency is expected to be low. The
   synchronous ioctl design is acceptable because the typical
   case is tens of commands per second at absolute peak
   (keyboard modifier LED toggles, startup RGB configuration).
   A shared-memory command path would add complexity without
   delivering value at this frequency.

4. If a future use case requires high-frequency lighting updates
   synchronised to audio or graphics (for instance, an
   equaliser-driven RGB keyboard), the mechanism is revisited.
   The ioctl path does not preclude adding a higher-throughput
   channel later; it simply does not solve that problem in v1.

5. Pattern and animation support is a non-trivial feature whose
   shape is hardware-vendor specific. Deferring it keeps v1
   focused on commands that every capable device can honour and
   avoids encoding vendor-specific assumptions into a general
   interface.

6. The capability descriptor is the interface clients read to
   know what commands to issue. Without it, clients either
   probe (inefficient, error-prone) or assume (wrong for
   heterogeneous hardware). Making capability part of the
   device inventory means every lighting-capable device is
   self-describing from the moment it enumerates.

7. Patterns are tracked as future work, not hedged. A post-
   Stage-B ADR adds pattern support once hardware experience
   during Stage B has clarified which primitives are
   portable across capable devices and which are not. The
   deferral is not an open question; it is a scheduled
   decision that requires data this project does not yet
   have.

## Notes

The lighting ioctl command codes, struct layouts, and error
values are specified in the companion header
`shared/include/inputfs_ioctl.h` or its Zig equivalent, to be
written before Stage B begins. This ADR commits to the interface
shape and capability model; byte-level specification lives in
the header.

The five roles in ADR 0004 remain unchanged. Lighting continues
to be a role endpoint; this ADR specifies the mechanism by which
that role is exercised without altering its status in the
taxonomy.

Haptic feedback, if added as a future role, would likely reuse
the same ioctl pattern. The precedent this ADR sets is: inbound
commands travel over ioctls on `/dev/inputfs`, not over shared
memory, until a specific use case justifies adding a higher-
throughput channel.

The v1 ioctl shape is designed to extend cleanly to a fourth
command variant without ABI break. The command-code space in
the companion header reserves unused values for future variants,
and the capability descriptor reserves a bit indicating
pattern-capable devices. These reservations are consumed by the
post-Stage-B patterns ADR rather than by any other feature, so
this ADR's v1 commitment and the patterns work do not contend
for the same reserved space.
