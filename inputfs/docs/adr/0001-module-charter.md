# 0001 inputfs module charter

Status: Proposed

## Context

UTF replaces evdev with a UTF-owned kernel input substrate. The
discipline document (`docs/UTF_ARCHITECTURAL_DISCIPLINE.md`)
classifies evdev, bsdinput, and libinput as external dependencies
inside UTF's guarantee path, to be addressed under the Replace
posture. The inputfs proposal
(`inputfs/docs/inputfs-proposal.md`) names the direction; the
foundations document (`inputfs/docs/foundations.md`) records the
cross-cutting decisions.

Replacement is entire, not partial. Any device class that inputfs
does not yet handle is work remaining, not a boundary where evdev
keeps operating. Coexistence defeats the discipline: if evdev
stays alive for gamepads, or pens, or vendor-specific devices,
UTF's determinism and stability guarantees remain dependent on
code not written with those guarantees in mind.

The hard path is the correct path. Fear of scale is the failure
mode that turns principled replacement into partial replacement —
the instinct to reduce apparent scope by keeping a subset of the
external dependency alive. UTF does not hedge against scale. The
work is substantial and is done anyway. Fixing legacy applications
that were not designed for UTF's ecosystem achieves little; the
root cause lives in the OS layer, and that is where UTF fixes it.
No external project is going to solve this for UTF — FreeBSD,
Linux, and libinput have their own goals, and those goals do not
align with UTF's guarantees. Waiting for external rescue is
waiting for a thing that will not arrive in the shape UTF needs.

This ADR states what inputfs is and what inputfs is not, so the
remaining Stage A ADRs have a fixed reference.

## Decision

1. inputfs is a kernel module at `/boot/modules/inputfs.ko`.

2. inputfs owns every input-device class FreeBSD exposes through
   its USB, HID, and legacy input infrastructure. Scope is total,
   not a selected subset.

3. inputfs owns: device enumeration, HID report parsing,
   coordinate normalisation into compositor space, event sequencing
   and timestamping, state publication, event ring publication,
   and focus-routed event delivery.

4. inputfs does not own: layout translation, compose and dead-key
   handling, IME integration, auto-repeat generation, gesture
   recognition. These are compositor or per-client concerns, per
   foundations §5.

5. Userspace interface is via shared-memory regions published under
   `/var/run/sema/input/` and via a kqueue-able fd at
   `/dev/inputfs`. No userspace daemon sits in the event path
   between inputfs and its consumers.

6. Naming: module `inputfs`, device node `/dev/inputfs`, sysctl
   namespace `hw.inputfs.*`, shared-memory root
   `/var/run/sema/input/`.

7. Implementation pace is staged per device class but the
   commitment to full replacement is not. Early stages implement
   the simplest classes (USB keyboards and mice); later stages
   add touchscreens, pens, tablets, gamepads, and vendor-specific
   devices. At no stage is a device class permanently routed
   through evdev.

## Consequences

1. Follow-on ADRs (shm layout, focus interface, role taxonomy)
   derive their scope from this charter.

2. Device classes not yet handled by inputfs are tracked as
   outstanding work, not as "evdev territory." AD-1 Stage B
   through Stage E in the inputfs proposal define the pace;
   BACKLOG.md tracks specific device-class milestones as they
   arise.

3. inputfs is not a drop-in replacement for evdev's ABI. Clients
   written to `/dev/input/event*` do not work against inputfs
   and are not expected to.

4. semainputd is retired when inputfs reaches functional parity
   with the evdev-driven pipeline. AD-2 in BACKLOG.md tracks
   the retirement.

## Notes

Scope only; design belongs in the follow-on ADRs. The Replace
posture from the discipline doc is the grounding: evdev is not
accepted as platform transport and is not partially accepted for
out-of-v1 device classes. It is replaced in full. The pace is
staged; the commitment is not.
