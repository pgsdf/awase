# Input Ioctl Interface

## Purpose

The input ioctl interface carries inbound commands from userspace
to the `inputfs` kernel module. In v1 it exposes three lighting
commands (`set_boolean`, `set_brightness`, `set_rgb`) as specified
in `inputfs/docs/adr/0005-lighting-command-mechanism.md`.

This is the fourth and final Stage A publication surface of
inputfs, complementing the three shared-memory regions (state,
events, focus). Unlike those, it is a traditional ioctl interface
on `/dev/inputfs`.

## Header files

**C header**: `shared/include/inputfs_ioctl.h`
Used by the kernel module and any direct C callers.

**Zig bindings**: `shared/src/inputfs_ioctl.zig`
Provides typed helpers and constants for Zig userspace (compositor,
tools). The Zig file mirrors the C header layouts exactly and
includes compile-time assertions on encoded ioctl values to detect
drift.

Both files guarantee identical struct layouts (`extern struct` in Zig).

## Ioctl group and numbering

All inputfs ioctls use group character `'I'` (`0x49`).

Command numbers occupy the range `0x00` to `0xFF`:

| Range | Purpose |
|-------|---------|
| `0x00` to `0x0F` | Diagnostic and statistics ioctls |
| `0x10` to `0x1F` | Lighting commands (v1 uses `0x10` to `0x12`) |
| `0x20` to `0x2F` | Future role-inbound commands |
| `0x30` to `0xFF` | General future expansion |

Within lighting:

- `0x10`: `set_boolean`
- `0x11`: `set_brightness`
- `0x12`: `set_rgb`
- `0x13` reserved for patterns (future)
- `0x14` to `0x1F` reserved

## Command structs

All structs are 8 bytes. All multi-byte fields are little-endian.

### `inputfs_light_set_boolean` (`0x10`)

```c
struct inputfs_light_set_boolean {
    uint16_t device_slot;   /* State region device inventory index */
    uint8_t  zone_index;    /* 0 to 17 */
    uint8_t  state;         /* 0 = off, 1 = on */
    uint32_t _pad;          /* reserved, zero */
};
```

ioctl: `_IOW('I', 0x10, struct inputfs_light_set_boolean)`

### `inputfs_light_set_brightness` (`0x11`)

```c
struct inputfs_light_set_brightness {
    uint16_t device_slot;
    uint8_t  zone_index;
    uint8_t  brightness;    /* 0 to 255 */
    uint32_t _pad;
};
```

ioctl: `_IOW('I', 0x11, struct inputfs_light_set_brightness)`

### `inputfs_light_set_rgb` (`0x12`)

```c
struct inputfs_light_set_rgb {
    uint16_t device_slot;
    uint8_t  zone_index;
    uint8_t  sub_zone;      /* 0 for single-zone; higher for arrays */
    uint8_t  r;
    uint8_t  g;
    uint8_t  b;
    uint16_t _pad;
};
```

ioctl: `_IOW('I', 0x12, struct inputfs_light_set_rgb)`

## Error codes

Returns `0` on success, `-1` with `errno` set on failure:

| errno | Meaning |
|-------|---------|
| `ENODEV` | Invalid or unused `device_slot` |
| `ENOENT` | Device lacks lighting role |
| `EINVAL` | Invalid `zone_index`, `sub_zone`, or reserved value |
| `ENOTSUP` | Zone type does not support this command |
| `EPERM` | Insufficient privileges |
| `EAGAIN` | Transient hardware error (retry ok) |
| `EIO` | Hardware error (state may be partial) |

Failed commands do not modify device state (except possibly on `EIO`).

## Capability discovery

Callers must consult the device's lighting capability descriptor in
the state region (`shared/INPUT_STATE.md`) before issuing commands.
The descriptor is authoritative for supported zones and types.

## API

### C

```c
#include <inputfs_ioctl.h>
#include <sys/ioctl.h>

int fd = open("/dev/inputfs", O_RDWR);
struct inputfs_light_set_rgb cmd = {
    .device_slot = 3,
    .zone_index = 0,
    .sub_zone = 0,
    .r = 0xFF, .g = 0x80, .b = 0x00,
};

if (ioctl(fd, INPUTFSIOC_LIGHT_SET_RGB, &cmd) < 0) {
    // handle errno
}
```

### Zig

```zig
const inputfs = @import("shared/src/inputfs_ioctl.zig");

const fd = try std.posix.open("/dev/inputfs", .{ .ACCMODE = .RDWR }, 0);
defer std.posix.close(fd);

const cmd = inputfs.SetRgb{
    .device_slot = 3,
    .zone_index = 0,
    .sub_zone = 0,
    .r = 0xFF,
    .g = 0x80,
    .b = 0x00,
};

try inputfs.setRgb(fd, cmd);  // returns Zig error set
```

## Versioning

No version field in structs. Command numbers and struct sizes are
immutable once published. New functionality requires a new command
number. Adding fields to an existing struct is breaking.

## Concurrency

Commands are synchronous. inputfs serialises commands to the same
device but allows concurrent execution across different devices.

## Integration

inputfs looks up the device by `device_slot`, validates against the
cached lighting capability descriptor from the state region, then
forwards to the hardware driver. The state region descriptor
remains the single source of truth for capabilities.

No events are generated in the event ring for lighting commands in v1.

References:

- `inputfs/docs/adr/0005-lighting-command-mechanism.md`
- `inputfs/docs/foundations.md` (§7 access control)
- `shared/INPUT_STATE.md` (lighting capability descriptor)
- `shared/INPUT_EVENTS.md`
- `drawfs/sys/dev/drawfs/drawfs_ioctl.h` (precedent)
