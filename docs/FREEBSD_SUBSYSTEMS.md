# FreeBSD Subsystem Disposition in UTF

This document lists FreeBSD subsystems that UTF touches and records
each subsystem's disposition under UTF's architectural discipline.
It is a navigation aid, not an authoritative source: the governing
document for each disposition is the ADR cited in the Reference
column. When a disposition changes, update the ADR first and this
table second.

## Why this document exists

UTF does not aim to be faster or lighter than FreeBSD's stock
input, graphics, or audio stacks. It aims for architectural
coherence: every component in UTF's guarantee path is either
owned by UTF or explicitly accepted as a named dependency.
Nothing in that path evolves invisibly to UTF.

Reliability, performance, and maintainability are likely
consequences of coherence, not goals in themselves. UTF accepts
that pursuing coherence sometimes produces code that is less
immediately performant or less feature-rich than what it
replaces. The architectural discipline document records the
trade-offs this entails.

This table is the inventory form of that discipline. Each row
states whether the listed FreeBSD subsystem is Replaced by UTF,
Accepted as a named dependency, or Removed from UTF Mode.

## Disposition categories

Dispositions use the three categories defined in
`docs/UTF_ARCHITECTURAL_DISCIPLINE.md`:

- **Replace**: UTF has its own implementation that takes over the
  subsystem's role.
- **Accept**: the subsystem is in UTF's guarantee path; UTF does
  not own it but relies on it, and this reliance is explicitly
  recorded.
- **Remove**: UTF excises reliance on the subsystem; it is not
  replaced by UTF and does not run under UTF Mode.

A fourth designation, **(unresolved)**, marks subsystems whose
disposition has not yet been decided. An entry in this state is a
prompt for a future ADR, not a commitment.

## System Model

Two modes are defined:

- **Base FreeBSD Mode**: stock FreeBSD with stock userland.
  Nothing UTF-specific is loaded. Input flows through evdev,
  graphics through Xorg or Wayland, audio through pulseaudio or
  similar.
- **UTF Mode**: UTF components are loaded and own their respective
  subsystems. Subsystems marked Replace or Remove below are absent
  or disabled at boot.

Switching between modes is a boot-configuration decision made via
`/boot/loader.conf` and rc configuration. Runtime transition is
out of scope.

## Input subsystem

| Subsystem | Disposition | Reference | Notes |
|-----------|-------------|-----------|-------|
| evdev | Replace | AD-1, inputfs-proposal | Replaced by inputfs (Stage E). |
| libinput | Remove | AD-1 | Consumes evdev; no role under UTF Mode. |
| moused | Remove | AD-1 Stage E | Userland mouse daemon; inputfs publishes state directly. |
| hms (HID mouse) | Replace | ADR 0007 | Displaced at boot under UTF Mode; source remains in FreeBSD tree. |
| hkbd (HID keyboard) | Replace | ADR 0007 | Displaced at boot under UTF Mode. |
| hgame (HID gamepad) | Replace | ADR 0007 | Displaced at boot under UTF Mode. |
| hcons (HID consumer controls) | Replace | ADR 0007 | Displaced at boot under UTF Mode. |
| hsctrl (HID system controls) | Replace | ADR 0007 | Displaced at boot under UTF Mode. |
| utouch (USB touchscreen) | Replace | ADR 0007 | Displaced at boot under UTF Mode. |
| hpen (HID digitizer pen) | Replace | ADR 0007 | Displaced at boot under UTF Mode if present. |
| hidmap (HID-to-evdev bridge) | Remove | ADR 0007 | Bridges to evdev, which UTF replaces; no role under UTF Mode. |
| hidbus (HID bus driver) | Accept | ADR 0007, `docs/UTF_USB_HID_BOUNDARY.md` | inputfs attaches as a hidbus child. |
| usbhid (USB-to-HID transport) | Accept | ADR 0007, `docs/UTF_USB_HID_BOUNDARY.md` | Transport layer below hidbus; not owned by UTF. |
| hid (HID protocol library) | Accept | ADR 0007, `docs/UTF_USB_HID_BOUNDARY.md` | `hid_start_parse`, `hid_get_item`, etc. used by inputfs. |
| devd (auto-load daemon) | (unresolved) | TBD | Auto-loads hms and friends; under UTF Mode, its input-related rules need to be scrubbed or the daemon configured to not fight inputfs. Observed during Stage B.2 testing. |
| sysmouse | (unresolved) | TBD | Kernel console mouse interface. Whether UTF coexists with or displaces this needs investigation. |
| kbdmux (keyboard multiplexer) | (unresolved) | TBD | Whether UTF owns this or displaces it is unclear. |
| vt(4) console input | (unresolved) | TBD | When inputfs owns HID keyboards under UTF Mode, the vt console loses keystrokes unless UTF provides its own console path. Scope decision pending. |

## Graphics subsystem

The graphics subsystem is owned by drawfs, tracked separately in
the drawfs proposal. Entries here are placeholders for items that
intersect drawfs's work.

| Subsystem | Disposition | Reference | Notes |
|-----------|-------------|-----------|-------|
| X.Org / Xorg-server | Remove | drawfs (TBD ADR) | Not part of UTF Mode. |
| Wayland compositors (via libinput) | Remove | drawfs (TBD ADR) | Excluded along with libinput. |
| vt(4) console output | (unresolved) | drawfs (TBD ADR) | drawfs owns graphics output; collision with vt at framebuffer level is analogous to inputfs vs hms at hidbus level. |
| DRM/KMS | Accept | drawfs | drawfs Phase 2 is built on DRM/KMS per drawfs project context. |

## Audio subsystem

Owned by audiofs and semasound, tracked as AD-3. All dispositions
resolved by the AD-3 decision record (ADRs 0001-0029).

| Subsystem | Disposition | Reference | Notes |
|-----------|-------------|-----------|-------|
| OSS / sound(4) | Removed | AD-3 Option A (ADR 0006) | snd(4) removed from the PGSD kernel in full, 2026-05-21; audiofs owns the hardware directly (class-matched PCI HDA). |
| pulseaudio | Remove | AD-3 (ADR 0006) | Not part of UTF Mode; semasound is the broker. (Historical observation retained: crashed during inputfs B.2 testing when hms churned; coupling to input device state was fragile.) |
| pipewire | Remove | AD-3 (ADR 0006) | Not part of UTF Mode. |
| sndio | Remove | AD-3 (ADR 0006) | Not part of UTF Mode. |
| snd_uaudio | Deferred | ADR 0008 section 3a | USB-audio-class is inside the AD-3 scope rule but has no instance on the confirmed target; a first instance enters by scope ADR, not by patch. |

## Desktop environment

| Subsystem | Disposition | Reference | Notes |
|-----------|-------------|-----------|-------|
| MATE / KDE / GNOME | Remove | UTF Mode definition | Assume evdev, dbus, Xorg; not part of UTF Mode. Not "deprecated", just absent. |
| dbus | (unresolved) | TBD | Widely assumed by desktop software. Accepted as an app-level dependency but not in UTF's guarantee path. Whether semadrawd itself uses dbus is a design question. |

## Infrastructure retained as-is

These FreeBSD subsystems are in UTF's guarantee path and are
retained. Listed for completeness so future readers can distinguish
"intentionally kept" from "not yet considered".

| Subsystem | Disposition | Notes |
|-----------|-------------|-------|
| kernel (FreeBSD) | Accept | UTF modules run inside the FreeBSD kernel. |
| ZFS | Accept (at PGSD layer) | UTF substrate is filesystem-agnostic; PGSD distribution requires ZFS. See `docs/UTF_STORAGE_DEPENDENCY.md`. |
| geom | Accept | Block layer. |
| devfs | Accept | Device filesystem. |
| rc.d | Accept | UTF services land here as new rc scripts. |
| network stack, ipfw, pf | Accept | UTF does not touch networking. |
| libc, libthr | Accept | Standard userland runtime. |
| clang, ld | Accept | Toolchain. |
| hier(7) filesystem layout | Accept | UTF installs follow FreeBSD conventions. |

## How to update this document

When an ADR changes a subsystem's disposition, update the ADR
first. Then:

1. Locate the row for the subsystem in the table above, or add a
   new row in the appropriate section.
2. Set the Disposition and Reference columns to match the ADR.
3. Write a concise Notes entry that captures the ADR's decision in
   one sentence.
4. Commit with a message referencing the ADR that motivated the
   change.

If an entry cannot be reduced to one of Replace / Accept / Remove,
leave it as `(unresolved)` until an ADR resolves it. Do not invent
new disposition categories without amending
`docs/UTF_ARCHITECTURAL_DISCIPLINE.md` first.

## Scope boundaries

This document records only subsystems UTF touches or may touch.
FreeBSD subsystems outside UTF's concern (mail transport, NFS
server, network time) are omitted. Adding an entry here is itself
a statement that UTF cares about the subsystem in some way.

Entries marked `(unresolved)` are invitations for future ADRs, not
backlog items. The relationship to BACKLOG.md is: if an unresolved
entry needs scheduled work, a BACKLOG item references this document
and an ADR is drafted.
