const std = @import("std");
const posix = std.posix;

// ============================================================================
// inputfs shared-memory regions
// ============================================================================
//
// This module exposes the userspace API for the four shared-memory regions
// that the inputfs kernel module publishes (state, events) or consumes
// (focus, smoothing). Per inputfs/docs/adr/0002-shared-memory-regions.md
// and adr/0015-per-user-pointer-smoothing.md, byte-level layouts live in
// shared/INPUT_STATE.md, shared/INPUT_EVENTS.md, shared/INPUT_FOCUS.md, and
// shared/INPUT_SMOOTHING.md. This file follows the patterns established in
// shared/src/clock.zig: little-endian, sequential-consistency atomics,
// magic-plus-version validation, non-fatal reader open.
//
// Four regions, four writer/reader pairs:
//
//   /var/run/sema/input/state      StateWriter (kernel) / StateReader
//   /var/run/sema/input/events     EventRingWriter (kernel) / EventRingReader
//   /var/run/sema/input/focus      FocusWriter (compositor) / FocusReader
//   /var/run/sema/input/smoothing  SmoothingWriter (compositor) / SmoothingReader
//
// State, focus, and smoothing use a header-level seqlock for atomic
// multi-field snapshots. Events use a per-slot seq field for the lock-free
// single-producer-multiple-consumer ring described in INPUT_EVENTS.md
// "Concurrency model".

// ============================================================================
// Shared helpers
// ============================================================================

fn writeU16(map: []u8, off: usize, v: u16) void {
    std.mem.writeInt(u16, map[off..][0..2], v, .little);
}

fn writeI32(map: []u8, off: usize, v: i32) void {
    std.mem.writeInt(i32, map[off..][0..4], v, .little);
}

fn writeU32(map: []u8, off: usize, v: u32) void {
    std.mem.writeInt(u32, map[off..][0..4], v, .little);
}

fn writeU64(map: []u8, off: usize, v: u64) void {
    std.mem.writeInt(u64, map[off..][0..8], v, .little);
}

/// Get a naturally-aligned `*u32` into a byte slice for atomic ops.
/// `std.mem.bytesAsValue` returns `*align(1) u32`; the atomic intrinsics
/// need the natural alignment, hence the `@alignCast`. Caller must ensure
/// `off` is u32-aligned within the region (true for all our header fields).
fn atomicU32Ptr(map: []u8, off: usize) *u32 {
    return @alignCast(std.mem.bytesAsValue(u32, map[off..][0..4]));
}

fn atomicU32PtrConst(map: []const u8, off: usize) *const u32 {
    return @alignCast(std.mem.bytesAsValue(u32, map[off..][0..4]));
}

fn atomicU64Ptr(map: []u8, off: usize) *u64 {
    return @alignCast(std.mem.bytesAsValue(u64, map[off..][0..8]));
}

fn atomicU64PtrConst(map: []const u8, off: usize) *const u64 {
    return @alignCast(std.mem.bytesAsValue(u64, map[off..][0..8]));
}

/// Ensure every ancestor directory of `path` exists, creating each level
/// as needed. Unlike `std.fs.makeDirAbsolute`, this handles the case where
/// multiple parents are missing (e.g. neither `/var/run/sema` nor
/// `/var/run/sema/input` exists yet on a fresh boot).
/// Raw-posix file helpers (ADR shared 0001/0002): this region library maps
/// shared memory directly via posix.mmap/munmap, so it adapts to the surviving
/// posix.system primitives rather than taking on std.Io. Mirrors the helpers in
/// shared/src/clock.zig; path null-termination and the error check live here.
fn openCreateRdwr(path: []const u8, mode: posix.mode_t) !posix.fd_t {
    var path_buf = try posix.toPosixPath(path);
    const fd = posix.system.open(&path_buf, .{ .ACCMODE = .RDWR, .CREAT = true, .TRUNC = true }, mode);
    if (fd < 0) return error.OpenFailed;
    return fd;
}

fn openReadOnly(path: []const u8) !posix.fd_t {
    var path_buf = try posix.toPosixPath(path);
    const fd = posix.system.open(&path_buf, .{ .ACCMODE = .RDONLY }, @as(posix.mode_t, 0));
    if (fd < 0) return error.OpenFailed;
    return fd;
}

fn fileSize(fd: posix.fd_t) !u64 {
    const end = posix.system.lseek(fd, 0, posix.SEEK.END);
    if (end < 0) return error.SeekFailed;
    return @intCast(end);
}

fn ensureParents(path: []const u8) !void {
    const dir = std.fs.path.dirname(path) orelse return;
    var i: usize = 0;
    while (i < dir.len) {
        // Skip leading slashes.
        while (i < dir.len and dir[i] == '/') : (i += 1) {}
        if (i >= dir.len) break;
        // Find end of this component.
        while (i < dir.len and dir[i] != '/') : (i += 1) {}
        const partial = dir[0..i];
        var dir_buf = posix.toPosixPath(partial) catch return error.NameTooLong;
        _ = posix.system.mkdir(&dir_buf, 0o755);
    }
}

// ============================================================================
// State region constants and layout
// ============================================================================
//
// Region:   /var/run/sema/input/state
// Total:    11,328 bytes (header 64 + 32*160 device + 32*64 keyboard
//           + 32*128 touch)
// Spec:     shared/INPUT_STATE.md

pub const STATE_PATH = "/var/run/sema/input/state";
pub const STATE_MAGIC: u32 = 0x494E5354; // "INST"
pub const STATE_VERSION: u8 = 1;
pub const STATE_SLOT_COUNT: u16 = 32;
pub const STATE_HEADER_SIZE: usize = 64;
pub const STATE_DEVICE_SLOT_SIZE: usize = 160;
pub const STATE_KEYBOARD_SLOT_SIZE: usize = 64;
pub const STATE_TOUCH_SLOT_SIZE: usize = 128;
pub const STATE_DEVICE_ARRAY_OFFSET: usize = STATE_HEADER_SIZE;
pub const STATE_KEYBOARD_ARRAY_OFFSET: usize =
    STATE_DEVICE_ARRAY_OFFSET + STATE_SLOT_COUNT * STATE_DEVICE_SLOT_SIZE;
pub const STATE_TOUCH_ARRAY_OFFSET: usize =
    STATE_KEYBOARD_ARRAY_OFFSET + STATE_SLOT_COUNT * STATE_KEYBOARD_SLOT_SIZE;
pub const STATE_SIZE: usize =
    STATE_TOUCH_ARRAY_OFFSET + STATE_SLOT_COUNT * STATE_TOUCH_SLOT_SIZE;

// Header field offsets within the state region.
const STATE_OFF_MAGIC: usize = 0;
const STATE_OFF_VERSION: usize = 4;
const STATE_OFF_VALID: usize = 5;
const STATE_OFF_SLOT_COUNT: usize = 6;
const STATE_OFF_SEQLOCK: usize = 8;
const STATE_OFF_LAST_SEQ: usize = 16;
const STATE_OFF_BOOT_OFFSET: usize = 24;
const STATE_OFF_PTR_X: usize = 32;
const STATE_OFF_PTR_Y: usize = 36;
const STATE_OFF_PTR_BUTTONS: usize = 40;
const STATE_OFF_DEVICE_COUNT: usize = 44;
const STATE_OFF_TOUCH_COUNT: usize = 46;
const STATE_OFF_TRANSFORM_ACTIVE: usize = 48;

// Device slot field offsets (relative to start of slot).
const DEV_OFF_DEVICE_ID: usize = 0;
const DEV_OFF_IDENTITY_HASH: usize = 16;
const DEV_OFF_ROLES: usize = 32;
const DEV_OFF_USB_VENDOR: usize = 36;
const DEV_OFF_USB_PRODUCT: usize = 38;
const DEV_OFF_NAME: usize = 40;
const DEV_OFF_LIGHTING_CAPS: usize = 104;

// Keyboard slot field offsets.
const KB_OFF_MODIFIERS: usize = 0;
const KB_OFF_HELD_COUNT: usize = 4;
const KB_OFF_HELD_KEYS: usize = 8;
pub const KB_MAX_HELD: usize = 6;
pub const KB_HELD_RECORD_SIZE: usize = 8;

// Touch slot field offsets.
const TOUCH_OFF_CONTACT_COUNT: usize = 0;
const TOUCH_OFF_CONTACTS: usize = 8;
pub const TOUCH_MAX_CONTACTS: usize = 10;
pub const TOUCH_CONTACT_SIZE: usize = 12;

// Role bits (per ADR 0010).
pub const ROLE_POINTER: u32 = 1 << 0;
pub const ROLE_KEYBOARD: u32 = 1 << 1;
pub const ROLE_TOUCH: u32 = 1 << 2;
pub const ROLE_PEN: u32 = 1 << 3;
pub const ROLE_LIGHTING: u32 = 1 << 4;

// ============================================================================
// Public state region types
// ============================================================================

pub const PointerState = struct {
    x: i32,
    y: i32,
    buttons: u32,
};

pub const HeldKey = struct {
    hid_usage: u32,
    positional: u32,
};

pub const KeyboardState = struct {
    modifiers: u32,
    held_count: u32,
    held_keys: [KB_MAX_HELD]HeldKey,
};

pub const TouchContact = struct {
    contact_id: u32,
    x: i32,
    y: i32,
};

pub const TouchState = struct {
    contact_count: u32,
    contacts: [TOUCH_MAX_CONTACTS]TouchContact,
};

pub const LightingZone = struct {
    type: u8, // 0 = unused, 1 = boolean/LED, 2 = brightness, 3 = RGB
    sub_zone_count: u8,
};

pub const LIGHTING_MAX_ZONES: usize = 18;

pub const LightingCaps = struct {
    zone_count: u8,
    flags: u8,
    zones: [LIGHTING_MAX_ZONES]LightingZone,
};

pub const DeviceDescriptor = struct {
    device_id: [16]u8,
    identity_hash: [16]u8,
    roles: u32,
    usb_vendor: u16,
    usb_product: u16,
    name: [64]u8, // null-padded
    lighting_caps: LightingCaps,
};

// ============================================================================
// StateWriter
// ============================================================================
//
// The kernel writer does not call this code (kernel context cannot link
// userspace Zig); it follows the same byte layout. The userspace writer
// exists for unit tests and for any future userspace-side simulator.

pub const StateWriter = struct {
    map: []u8,
    fd: posix.fd_t,

    pub fn init(path: []const u8) !StateWriter {
        try ensureParents(path);

        // Mode 0o600 per ADR 0013; operators relax via daemon's
        // process group and umask, not code.
        const raw_fd = try openCreateRdwr(path, 0o600);
        errdefer _ = posix.system.close(raw_fd);

        if (posix.system.ftruncate(raw_fd, @intCast(STATE_SIZE)) != 0) return error.TruncateFailed;

        const map_raw = try posix.mmap(
            null,
            STATE_SIZE,
            .{ .READ = true, .WRITE = true },
            .{ .TYPE = .SHARED },
            raw_fd,
            0,
        );
        errdefer posix.munmap(map_raw);

        const map: []u8 = map_raw[0..STATE_SIZE];
        @memset(map, 0);

        const writer = StateWriter{ .map = map, .fd = raw_fd };
        writeU32(map, STATE_OFF_MAGIC, STATE_MAGIC);
        map[STATE_OFF_VERSION] = STATE_VERSION;
        map[STATE_OFF_VALID] = 0;
        writeU16(map, STATE_OFF_SLOT_COUNT, STATE_SLOT_COUNT);
        writeU32(map, STATE_OFF_SEQLOCK, 0);
        writeU64(map, STATE_OFF_LAST_SEQ, 0);
        writeU64(map, STATE_OFF_BOOT_OFFSET, 0);

        return writer;
    }

    pub fn deinit(self: StateWriter) void {
        posix.munmap(@alignCast(self.map));
        _ = posix.system.close(self.fd);
    }

    /// Mark the region live. Call once after enumeration completes.
    /// state_valid is set once (0 -> 1) and never reset.
    pub fn markValid(self: StateWriter) void {
        @atomicStore(u8, &self.map[STATE_OFF_VALID], 1, .seq_cst);
    }

    /// Begin a write batch. Increments the seqlock to an odd value;
    /// readers see this as "write in progress" and retry.
    pub fn beginUpdate(self: StateWriter) void {
        const ptr = atomicU32Ptr(self.map, STATE_OFF_SEQLOCK);
        const cur = @atomicLoad(u32, ptr, .seq_cst);
        @atomicStore(u32, ptr, cur + 1, .seq_cst);
    }

    /// End a write batch. Increments the seqlock again to an even value.
    /// Readers that see the same even value before and after their read
    /// know the snapshot is consistent.
    pub fn endUpdate(self: StateWriter) void {
        const ptr = atomicU32Ptr(self.map, STATE_OFF_SEQLOCK);
        const cur = @atomicLoad(u32, ptr, .seq_cst);
        @atomicStore(u32, ptr, cur + 1, .seq_cst);
    }

    pub fn setPointer(self: StateWriter, p: PointerState) void {
        writeI32(self.map, STATE_OFF_PTR_X, p.x);
        writeI32(self.map, STATE_OFF_PTR_Y, p.y);
        writeU32(self.map, STATE_OFF_PTR_BUTTONS, p.buttons);
    }

    pub fn setLastSequence(self: StateWriter, seq: u64) void {
        writeU64(self.map, STATE_OFF_LAST_SEQ, seq);
    }

    pub fn setBootOffsetNs(self: StateWriter, offset: u64) void {
        writeU64(self.map, STATE_OFF_BOOT_OFFSET, offset);
    }

    /// Place a device descriptor at the given slot index.
    /// Caller is responsible for choosing a free slot and updating
    /// device_count via setDeviceCount.
    pub fn putDevice(self: StateWriter, slot: usize, dev: DeviceDescriptor) !void {
        if (slot >= STATE_SLOT_COUNT) return error.SlotOutOfRange;
        const base = STATE_DEVICE_ARRAY_OFFSET + slot * STATE_DEVICE_SLOT_SIZE;
        @memcpy(self.map[base + DEV_OFF_DEVICE_ID ..][0..16], &dev.device_id);
        @memcpy(self.map[base + DEV_OFF_IDENTITY_HASH ..][0..16], &dev.identity_hash);
        writeU32(self.map, base + DEV_OFF_ROLES, dev.roles);
        writeU16(self.map, base + DEV_OFF_USB_VENDOR, dev.usb_vendor);
        writeU16(self.map, base + DEV_OFF_USB_PRODUCT, dev.usb_product);
        @memcpy(self.map[base + DEV_OFF_NAME ..][0..64], &dev.name);
        const lc_base = base + DEV_OFF_LIGHTING_CAPS;
        self.map[lc_base + 0] = dev.lighting_caps.zone_count;
        self.map[lc_base + 1] = dev.lighting_caps.flags;
        var i: usize = 0;
        while (i < LIGHTING_MAX_ZONES) : (i += 1) {
            const z_off = lc_base + 2 + i * 3;
            self.map[z_off + 0] = dev.lighting_caps.zones[i].type;
            self.map[z_off + 1] = dev.lighting_caps.zones[i].sub_zone_count;
            self.map[z_off + 2] = 0; // reserved
        }
    }

    pub fn clearDevice(self: StateWriter, slot: usize) !void {
        if (slot >= STATE_SLOT_COUNT) return error.SlotOutOfRange;
        const base = STATE_DEVICE_ARRAY_OFFSET + slot * STATE_DEVICE_SLOT_SIZE;
        @memset(self.map[base..][0..STATE_DEVICE_SLOT_SIZE], 0);
    }

    pub fn setDeviceCount(self: StateWriter, count: u16) void {
        writeU16(self.map, STATE_OFF_DEVICE_COUNT, count);
    }

    pub fn setActiveTouchCount(self: StateWriter, count: u16) void {
        writeU16(self.map, STATE_OFF_TOUCH_COUNT, count);
    }

    pub fn setTransformActive(self: StateWriter, active: u8) void {
        self.map[STATE_OFF_TRANSFORM_ACTIVE] = active;
    }

    pub fn setKeyboardState(self: StateWriter, slot: usize, kb: KeyboardState) !void {
        if (slot >= STATE_SLOT_COUNT) return error.SlotOutOfRange;
        const base = STATE_KEYBOARD_ARRAY_OFFSET + slot * STATE_KEYBOARD_SLOT_SIZE;
        writeU32(self.map, base + KB_OFF_MODIFIERS, kb.modifiers);
        writeU32(self.map, base + KB_OFF_HELD_COUNT, kb.held_count);
        var i: usize = 0;
        while (i < KB_MAX_HELD) : (i += 1) {
            const off = base + KB_OFF_HELD_KEYS + i * KB_HELD_RECORD_SIZE;
            writeU32(self.map, off + 0, kb.held_keys[i].hid_usage);
            writeU32(self.map, off + 4, kb.held_keys[i].positional);
        }
    }

    pub fn setTouchState(self: StateWriter, slot: usize, t: TouchState) !void {
        if (slot >= STATE_SLOT_COUNT) return error.SlotOutOfRange;
        const base = STATE_TOUCH_ARRAY_OFFSET + slot * STATE_TOUCH_SLOT_SIZE;
        writeU32(self.map, base + TOUCH_OFF_CONTACT_COUNT, t.contact_count);
        var i: usize = 0;
        while (i < TOUCH_MAX_CONTACTS) : (i += 1) {
            const off = base + TOUCH_OFF_CONTACTS + i * TOUCH_CONTACT_SIZE;
            writeU32(self.map, off + 0, t.contacts[i].contact_id);
            writeI32(self.map, off + 4, t.contacts[i].x);
            writeI32(self.map, off + 8, t.contacts[i].y);
        }
    }
};

// ============================================================================
// StateReader
// ============================================================================

pub const StateSnapshot = struct {
    pointer_x: i32,
    pointer_y: i32,
    pointer_buttons: u32,
    device_count: u16,
    active_touch_count: u16,
    transform_active: u8,
    last_sequence: u64,
    boot_wall_offset_ns: u64,
    devices: [STATE_SLOT_COUNT]DeviceDescriptor,
    keyboards: [STATE_SLOT_COUNT]KeyboardState,
    touches: [STATE_SLOT_COUNT]TouchState,

    pub fn pointer(self: StateSnapshot) PointerState {
        return .{
            .x = self.pointer_x,
            .y = self.pointer_y,
            .buttons = self.pointer_buttons,
        };
    }

    pub fn findDeviceSlot(self: StateSnapshot, id: [16]u8) ?usize {
        var i: usize = 0;
        while (i < STATE_SLOT_COUNT) : (i += 1) {
            if (std.mem.eql(u8, &self.devices[i].device_id, &id)) return i;
        }
        return null;
    }

    pub fn keyboardForDevice(self: StateSnapshot, id: [16]u8) ?KeyboardState {
        const slot = self.findDeviceSlot(id) orelse return null;
        if (self.devices[slot].roles & ROLE_KEYBOARD == 0) return null;
        return self.keyboards[slot];
    }

    pub fn touchForDevice(self: StateSnapshot, id: [16]u8) ?TouchState {
        const slot = self.findDeviceSlot(id) orelse return null;
        if (self.devices[slot].roles & ROLE_TOUCH == 0) return null;
        return self.touches[slot];
    }
};

pub const StateReader = struct {
    map: ?[]const u8,
    fd: posix.fd_t,

    pub fn init(path: []const u8) StateReader {
        const raw_fd = openReadOnly(path) catch {
            return .{ .map = null, .fd = -1 };
        };

        // Defensive: confirm the file is at least STATE_SIZE bytes
        // before mmap-ing. mmap with a length larger than the file
        // succeeds, but reads past the file's actual end fault with
        // SIGBUS or SIGSEGV. This commonly happens during
        // semainputd's bringup window: createFileAbsolute(truncate=true)
        // produces a 0-byte file before setEndPos grows it; if a reader
        // (e.g. semadrawd's cursor pump) opens during that window, every
        // byte read past the actual file end is a fault. The same
        // pattern applies if semainputd has crashed mid-init, leaving
        // a too-short file on disk.
        //
        // The right behaviour for the reader is: treat "file too short"
        // identically to "file does not exist" — return an empty
        // StateReader so the caller's existing retry path takes over.
        const end_pos = fileSize(raw_fd) catch {
            _ = posix.system.close(raw_fd);
            return .{ .map = null, .fd = -1 };
        };
        if (end_pos < @as(u64, STATE_SIZE)) {
            _ = posix.system.close(raw_fd);
            return .{ .map = null, .fd = -1 };
        }

        const map_raw = posix.mmap(
            null,
            STATE_SIZE,
            .{ .READ = true },
            .{ .TYPE = .SHARED },
            raw_fd,
            0,
        ) catch {
            _ = posix.system.close(raw_fd);
            return .{ .map = null, .fd = -1 };
        };

        const map: []const u8 = map_raw[0..STATE_SIZE];
        const magic = std.mem.readInt(u32, map[STATE_OFF_MAGIC..][0..4], .little);
        if (magic != STATE_MAGIC or map[STATE_OFF_VERSION] != STATE_VERSION) {
            posix.munmap(@alignCast(map_raw));
            _ = posix.system.close(raw_fd);
            return .{ .map = null, .fd = -1 };
        }

        return .{ .map = map, .fd = raw_fd };
    }

    pub fn deinit(self: StateReader) void {
        if (self.map) |m| posix.munmap(@alignCast(@constCast(m)));
        if (self.fd >= 0) _ = posix.system.close(self.fd);
    }

    pub fn isValid(self: StateReader) bool {
        const m = self.map orelse return false;
        return @atomicLoad(u8, &m[STATE_OFF_VALID], .seq_cst) != 0;
    }

    /// Narrow snapshot reading only pointer fields (x, y, buttons).
    /// Returns null if the state region is not currently valid.
    ///
    /// Same seqlock pattern as snapshot() but skips the multi-KB
    /// device/keyboard/touch slot copy. Intended for hot-path
    /// callers that only need pointer position — for example
    /// semadrawd's cursor surface position pump (AD-21 sub-item 5),
    /// which runs once per composition cycle.
    ///
    /// Returns error.NotOpen if the StateReader was never
    /// initialised; error.SeqlockContended after MAX_ATTEMPTS
    /// retries (same threshold as snapshot()).
    pub fn pointerSnapshot(self: StateReader) !?PointerState {
        const m = self.map orelse return error.NotOpen;
        if (@atomicLoad(u8, &m[STATE_OFF_VALID], .seq_cst) == 0) return null;

        const seqlock_ptr = atomicU32PtrConst(m, STATE_OFF_SEQLOCK);

        var attempt: usize = 0;
        const MAX_ATTEMPTS: usize = 1024;
        while (attempt < MAX_ATTEMPTS) : (attempt += 1) {
            const v1 = @atomicLoad(u32, seqlock_ptr, .seq_cst);
            if (v1 & 1 != 0) {
                std.atomic.spinLoopHint();
                continue;
            }

            var ps: PointerState = undefined;
            ps.x = std.mem.readInt(i32, m[STATE_OFF_PTR_X..][0..4], .little);
            ps.y = std.mem.readInt(i32, m[STATE_OFF_PTR_Y..][0..4], .little);
            ps.buttons = std.mem.readInt(u32, m[STATE_OFF_PTR_BUTTONS..][0..4], .little);

            const v2 = @atomicLoad(u32, seqlock_ptr, .seq_cst);
            if (v2 == v1) return ps;
        }
        return error.SeqlockContended;
    }

    /// Read a consistent snapshot using the seqlock pattern from
    /// INPUT_STATE.md "Concurrency model".
    pub fn snapshot(self: StateReader) !StateSnapshot {
        const m = self.map orelse return error.NotOpen;
        const seqlock_ptr = atomicU32PtrConst(m, STATE_OFF_SEQLOCK);

        var attempt: usize = 0;
        const MAX_ATTEMPTS: usize = 1024;
        while (attempt < MAX_ATTEMPTS) : (attempt += 1) {
            const v1 = @atomicLoad(u32, seqlock_ptr, .seq_cst);
            if (v1 & 1 != 0) {
                std.atomic.spinLoopHint();
                continue;
            }

            var snap: StateSnapshot = undefined;
            snap.pointer_x = std.mem.readInt(i32, m[STATE_OFF_PTR_X..][0..4], .little);
            snap.pointer_y = std.mem.readInt(i32, m[STATE_OFF_PTR_Y..][0..4], .little);
            snap.pointer_buttons = std.mem.readInt(u32, m[STATE_OFF_PTR_BUTTONS..][0..4], .little);
            snap.device_count = std.mem.readInt(u16, m[STATE_OFF_DEVICE_COUNT..][0..2], .little);
            snap.active_touch_count = std.mem.readInt(u16, m[STATE_OFF_TOUCH_COUNT..][0..2], .little);
            snap.transform_active = m[STATE_OFF_TRANSFORM_ACTIVE];
            snap.last_sequence = std.mem.readInt(u64, m[STATE_OFF_LAST_SEQ..][0..8], .little);
            snap.boot_wall_offset_ns = std.mem.readInt(u64, m[STATE_OFF_BOOT_OFFSET..][0..8], .little);

            var i: usize = 0;
            while (i < STATE_SLOT_COUNT) : (i += 1) {
                snap.devices[i] = readDevice(m, i);
                snap.keyboards[i] = readKeyboard(m, i);
                snap.touches[i] = readTouch(m, i);
            }

            const v2 = @atomicLoad(u32, seqlock_ptr, .seq_cst);
            if (v2 == v1) return snap;
        }
        return error.SeqlockContended;
    }

    fn readDevice(m: []const u8, slot: usize) DeviceDescriptor {
        const base = STATE_DEVICE_ARRAY_OFFSET + slot * STATE_DEVICE_SLOT_SIZE;
        var dev: DeviceDescriptor = undefined;
        @memcpy(&dev.device_id, m[base + DEV_OFF_DEVICE_ID ..][0..16]);
        @memcpy(&dev.identity_hash, m[base + DEV_OFF_IDENTITY_HASH ..][0..16]);
        dev.roles = std.mem.readInt(u32, m[base + DEV_OFF_ROLES ..][0..4], .little);
        dev.usb_vendor = std.mem.readInt(u16, m[base + DEV_OFF_USB_VENDOR ..][0..2], .little);
        dev.usb_product = std.mem.readInt(u16, m[base + DEV_OFF_USB_PRODUCT ..][0..2], .little);
        @memcpy(&dev.name, m[base + DEV_OFF_NAME ..][0..64]);
        const lc_base = base + DEV_OFF_LIGHTING_CAPS;
        dev.lighting_caps.zone_count = m[lc_base + 0];
        dev.lighting_caps.flags = m[lc_base + 1];
        var i: usize = 0;
        while (i < LIGHTING_MAX_ZONES) : (i += 1) {
            const z_off = lc_base + 2 + i * 3;
            dev.lighting_caps.zones[i].type = m[z_off + 0];
            dev.lighting_caps.zones[i].sub_zone_count = m[z_off + 1];
        }
        return dev;
    }

    fn readKeyboard(m: []const u8, slot: usize) KeyboardState {
        const base = STATE_KEYBOARD_ARRAY_OFFSET + slot * STATE_KEYBOARD_SLOT_SIZE;
        var kb: KeyboardState = undefined;
        kb.modifiers = std.mem.readInt(u32, m[base + KB_OFF_MODIFIERS ..][0..4], .little);
        kb.held_count = std.mem.readInt(u32, m[base + KB_OFF_HELD_COUNT ..][0..4], .little);
        var i: usize = 0;
        while (i < KB_MAX_HELD) : (i += 1) {
            const off = base + KB_OFF_HELD_KEYS + i * KB_HELD_RECORD_SIZE;
            kb.held_keys[i].hid_usage = std.mem.readInt(u32, m[off + 0 ..][0..4], .little);
            kb.held_keys[i].positional = std.mem.readInt(u32, m[off + 4 ..][0..4], .little);
        }
        return kb;
    }

    fn readTouch(m: []const u8, slot: usize) TouchState {
        const base = STATE_TOUCH_ARRAY_OFFSET + slot * STATE_TOUCH_SLOT_SIZE;
        var t: TouchState = undefined;
        t.contact_count = std.mem.readInt(u32, m[base + TOUCH_OFF_CONTACT_COUNT ..][0..4], .little);
        var i: usize = 0;
        while (i < TOUCH_MAX_CONTACTS) : (i += 1) {
            const off = base + TOUCH_OFF_CONTACTS + i * TOUCH_CONTACT_SIZE;
            t.contacts[i].contact_id = std.mem.readInt(u32, m[off + 0 ..][0..4], .little);
            t.contacts[i].x = std.mem.readInt(i32, m[off + 4 ..][0..4], .little);
            t.contacts[i].y = std.mem.readInt(i32, m[off + 8 ..][0..4], .little);
        }
        return t;
    }
};

// ============================================================================
// Event ring constants and layout
// ============================================================================
//
// Region:   /var/run/sema/input/events
// Total:    65,600 bytes (header 64 + 1024 slots * 64 bytes)
// Spec:     shared/INPUT_EVENTS.md

pub const EVENTS_PATH = "/var/run/sema/input/events";
pub const EVENTS_MAGIC: u32 = 0x494E5645; // "INVE"
pub const EVENTS_VERSION: u8 = 1;
pub const EVENTS_HEADER_SIZE: usize = 64;
pub const EVENTS_SLOT_SIZE: usize = 64;
pub const EVENTS_SLOT_COUNT: u32 = 1024;

// AD-41.3 notification surface (per inputfs/docs/adr/0021).
// This is a kernel-side cdev created by the inputfs module
// alongside the mmap-backed events region above. Userspace
// opens this path purely to add the resulting fd to a
// poll(2) / kevent(2) set; reads, writes, ioctls, and
// mmap on the cdev return EOPNOTSUPP. Event data continues
// to flow via the mmap'd EVENTS_PATH file.
//
// Userspace consumers MUST treat the open as best-effort:
// the cdev may be absent (kernel module not loaded, or
// loaded against an older version of inputfs that predates
// AD-41.3). In that case the consumer falls back to the
// poll-timeout-based drain cadence semadrawd had before
// AD-41.
pub const NOTIFY_DEV_PATH = "/dev/inputfs_notify";
pub const EVENTS_SIZE: usize =
    EVENTS_HEADER_SIZE + EVENTS_SLOT_COUNT * EVENTS_SLOT_SIZE;

const EV_OFF_MAGIC: usize = 0;
const EV_OFF_VERSION: usize = 4;
const EV_OFF_VALID: usize = 5;
const EV_OFF_EVENT_SIZE: usize = 6;
const EV_OFF_SLOT_COUNT: usize = 8;
const EV_OFF_WRITER_SEQ: usize = 16;
const EV_OFF_EARLIEST_SEQ: usize = 24;

const EV_SLOT_OFF_SEQ: usize = 0;
const EV_SLOT_OFF_TS_ORDERING: usize = 8;
const EV_SLOT_OFF_TS_SYNC: usize = 16;
const EV_SLOT_OFF_DEVICE_SLOT: usize = 24;
const EV_SLOT_OFF_SOURCE_ROLE: usize = 26;
const EV_SLOT_OFF_EVENT_TYPE: usize = 27;
const EV_SLOT_OFF_FLAGS: usize = 28;
const EV_SLOT_OFF_PAYLOAD: usize = 32;

pub const SOURCE_POINTER: u8 = 1;
pub const SOURCE_KEYBOARD: u8 = 2;
pub const SOURCE_TOUCH: u8 = 3;
pub const SOURCE_PEN: u8 = 4;
pub const SOURCE_LIGHTING: u8 = 5;
pub const SOURCE_DEVICE_LIFECYCLE: u8 = 6;

// Per-source-role event_type constants. Promoted from
// duplicated definitions in semadraw/src/backend/inputfs_input.zig
// and semadraw/src/daemon/semadrawd.zig under AD-2a Phase 3
// (cleanup surfaced during Phase 2.4). The numeric values match
// inputfs's wire format and must not be changed without
// coordinating both producer (inputfs kernel) and consumer
// (semadrawd) sides. event_type is one byte and only meaningful
// in the context of a specific source_role; the same numeric
// value can mean different things under different roles
// (POINTER_MOTION = 1 under SOURCE_POINTER; TOUCH_DOWN = 1 under
// SOURCE_TOUCH).

// SOURCE_POINTER:
pub const POINTER_MOTION: u8 = 1;
pub const POINTER_BUTTON_DOWN: u8 = 2;
pub const POINTER_BUTTON_UP: u8 = 3;
pub const POINTER_SCROLL: u8 = 4;

// SOURCE_TOUCH:
pub const TOUCH_DOWN: u8 = 1;
pub const TOUCH_MOVE: u8 = 2;
pub const TOUCH_UP: u8 = 3;

pub const FLAG_SYNTHESISED: u32 = 1 << 0;
pub const FLAG_COALESCED: u32 = 1 << 1;

pub const SYNTHETIC_DEVICE: u16 = 0xFFFF;

/// One event as written or read. The 32-byte payload is left as raw bytes;
/// callers interpret it according to (source_role, event_type) per the spec.
pub const Event = struct {
    seq: u64,
    ts_ordering: u64,
    ts_sync: u64,
    device_slot: u16,
    source_role: u8,
    event_type: u8,
    flags: u32,
    payload: [32]u8,
};

// ============================================================================
// EventRingWriter
// ============================================================================

pub const EventRingWriter = struct {
    map: []u8,
    fd: posix.fd_t,
    writer_seq: u64,

    pub fn init(path: []const u8) !EventRingWriter {
        try ensureParents(path);

        // Mode 0o600 per ADR 0013; operators relax via daemon's
        // process group and umask, not code.
        const raw_fd = try openCreateRdwr(path, 0o600);
        errdefer _ = posix.system.close(raw_fd);

        if (posix.system.ftruncate(raw_fd, @intCast(EVENTS_SIZE)) != 0) return error.TruncateFailed;

        const map_raw = try posix.mmap(
            null,
            EVENTS_SIZE,
            .{ .READ = true, .WRITE = true },
            .{ .TYPE = .SHARED },
            raw_fd,
            0,
        );
        errdefer posix.munmap(map_raw);

        const map: []u8 = map_raw[0..EVENTS_SIZE];
        @memset(map, 0);

        const writer = EventRingWriter{ .map = map, .fd = raw_fd, .writer_seq = 0 };

        writeU32(map, EV_OFF_MAGIC, EVENTS_MAGIC);
        map[EV_OFF_VERSION] = EVENTS_VERSION;
        map[EV_OFF_VALID] = 0;
        writeU16(map, EV_OFF_EVENT_SIZE, @intCast(EVENTS_SLOT_SIZE));
        writeU32(map, EV_OFF_SLOT_COUNT, EVENTS_SLOT_COUNT);
        writeU64(map, EV_OFF_WRITER_SEQ, 0);
        // earliest_seq starts at 1: "no events yet, the next event is seq=1".
        writeU64(map, EV_OFF_EARLIEST_SEQ, 1);

        return writer;
    }

    pub fn deinit(self: EventRingWriter) void {
        posix.munmap(@alignCast(self.map));
        _ = posix.system.close(self.fd);
    }

    pub fn markValid(self: EventRingWriter) void {
        @atomicStore(u8, &self.map[EV_OFF_VALID], 1, .seq_cst);
    }

    /// Publish an event to the ring. Assigns the next sequence number.
    /// Follows the writer protocol from INPUT_EVENTS.md "Concurrency model":
    /// write all fields except seq, publish seq atomically, advance
    /// writer_seq, update earliest_seq if the ring wrapped.
    pub fn publish(self: *EventRingWriter, e: Event) void {
        const new_seq = self.writer_seq + 1;
        const slot_idx = new_seq & (EVENTS_SLOT_COUNT - 1);
        const slot_base = EVENTS_HEADER_SIZE + slot_idx * EVENTS_SLOT_SIZE;

        // Step 1: zero seq during the body write so a concurrent reader
        // sees an inconsistent slot and retries.
        const seq_ptr = atomicU64Ptr(self.map, slot_base + EV_SLOT_OFF_SEQ);
        @atomicStore(u64, seq_ptr, 0, .seq_cst);

        writeU64(self.map, slot_base + EV_SLOT_OFF_TS_ORDERING, e.ts_ordering);
        writeU64(self.map, slot_base + EV_SLOT_OFF_TS_SYNC, e.ts_sync);
        writeU16(self.map, slot_base + EV_SLOT_OFF_DEVICE_SLOT, e.device_slot);
        self.map[slot_base + EV_SLOT_OFF_SOURCE_ROLE] = e.source_role;
        self.map[slot_base + EV_SLOT_OFF_EVENT_TYPE] = e.event_type;
        writeU32(self.map, slot_base + EV_SLOT_OFF_FLAGS, e.flags);
        @memcpy(self.map[slot_base + EV_SLOT_OFF_PAYLOAD ..][0..32], &e.payload);

        // Step 2: publish seq atomically.
        @atomicStore(u64, seq_ptr, new_seq, .seq_cst);

        // Step 3: advance writer_seq.
        self.writer_seq = new_seq;
        @atomicStore(u64, atomicU64Ptr(self.map, EV_OFF_WRITER_SEQ), new_seq, .seq_cst);

        // Step 4: if the ring has wrapped, advance earliest_seq.
        if (new_seq > EVENTS_SLOT_COUNT) {
            const new_earliest = new_seq - EVENTS_SLOT_COUNT + 1;
            @atomicStore(u64, atomicU64Ptr(self.map, EV_OFF_EARLIEST_SEQ), new_earliest, .seq_cst);
        }
    }
};

// ============================================================================
// EventRingReader
// ============================================================================

pub const RingDrainResult = struct {
    events_consumed: usize,
    overrun: bool,
};

pub const EventRingReader = struct {
    map: ?[]const u8,
    fd: posix.fd_t,
    last_consumed: u64,

    pub fn init(path: []const u8) EventRingReader {
        const raw_fd = openReadOnly(path) catch {
            return .{ .map = null, .fd = -1, .last_consumed = 0 };
        };

        // Defensive size check before mmap. See StateReader.init for
        // the rationale: an mmap larger than the backing file's size
        // succeeds, but reads past the file's end fault SIGBUS/SIGSEGV.
        // Common during bringup when semainputd has created the file
        // (truncate=true → 0 bytes) but not yet called setEndPos.
        const end_pos = fileSize(raw_fd) catch {
            _ = posix.system.close(raw_fd);
            return .{ .map = null, .fd = -1, .last_consumed = 0 };
        };
        if (end_pos < @as(u64, EVENTS_SIZE)) {
            _ = posix.system.close(raw_fd);
            return .{ .map = null, .fd = -1, .last_consumed = 0 };
        }

        const map_raw = posix.mmap(
            null,
            EVENTS_SIZE,
            .{ .READ = true },
            .{ .TYPE = .SHARED },
            raw_fd,
            0,
        ) catch {
            _ = posix.system.close(raw_fd);
            return .{ .map = null, .fd = -1, .last_consumed = 0 };
        };

        const map: []const u8 = map_raw[0..EVENTS_SIZE];
        const magic = std.mem.readInt(u32, map[EV_OFF_MAGIC..][0..4], .little);
        if (magic != EVENTS_MAGIC or map[EV_OFF_VERSION] != EVENTS_VERSION) {
            posix.munmap(@alignCast(map_raw));
            _ = posix.system.close(raw_fd);
            return .{ .map = null, .fd = -1, .last_consumed = 0 };
        }

        return .{ .map = map, .fd = raw_fd, .last_consumed = 0 };
    }

    pub fn deinit(self: EventRingReader) void {
        if (self.map) |m| posix.munmap(@alignCast(@constCast(m)));
        if (self.fd >= 0) _ = posix.system.close(self.fd);
    }

    pub fn isValid(self: EventRingReader) bool {
        const m = self.map orelse return false;
        return @atomicLoad(u8, &m[EV_OFF_VALID], .seq_cst) != 0;
    }

    pub fn writerSeq(self: EventRingReader) u64 {
        const m = self.map orelse return 0;
        return @atomicLoad(u64, atomicU64PtrConst(m, EV_OFF_WRITER_SEQ), .seq_cst);
    }

    pub fn earliestSeq(self: EventRingReader) u64 {
        const m = self.map orelse return 0;
        return @atomicLoad(u64, atomicU64PtrConst(m, EV_OFF_EARLIEST_SEQ), .seq_cst);
    }

    /// Drain newly published events into `out`. Returns the count consumed
    /// and whether overrun was detected. On overrun, last_consumed is
    /// repositioned to earliestSeq() - 1; the caller should resynchronise
    /// from the state region per INPUT_EVENTS.md "Failure modes".
    pub fn drain(self: *EventRingReader, out: []Event) !RingDrainResult {
        const m = self.map orelse return error.NotOpen;
        const writer_seq = @atomicLoad(u64, atomicU64PtrConst(m, EV_OFF_WRITER_SEQ), .seq_cst);
        const earliest = @atomicLoad(u64, atomicU64PtrConst(m, EV_OFF_EARLIEST_SEQ), .seq_cst);

        var overrun = false;
        if (earliest > 0 and self.last_consumed + 1 < earliest) {
            overrun = true;
            self.last_consumed = earliest - 1;
        }

        var consumed: usize = 0;
        var next = self.last_consumed + 1;
        while (next <= writer_seq and consumed < out.len) : (next += 1) {
            const slot_idx = next & (EVENTS_SLOT_COUNT - 1);
            const slot_base = EVENTS_HEADER_SIZE + slot_idx * EVENTS_SLOT_SIZE;
            const seq_ptr = atomicU64PtrConst(m, slot_base + EV_SLOT_OFF_SEQ);

            const seq1 = @atomicLoad(u64, seq_ptr, .seq_cst);
            if (seq1 != next) {
                std.atomic.spinLoopHint();
                continue;
            }

            var ev: Event = undefined;
            ev.seq = seq1;
            ev.ts_ordering = std.mem.readInt(u64, m[slot_base + EV_SLOT_OFF_TS_ORDERING ..][0..8], .little);
            ev.ts_sync = std.mem.readInt(u64, m[slot_base + EV_SLOT_OFF_TS_SYNC ..][0..8], .little);
            ev.device_slot = std.mem.readInt(u16, m[slot_base + EV_SLOT_OFF_DEVICE_SLOT ..][0..2], .little);
            ev.source_role = m[slot_base + EV_SLOT_OFF_SOURCE_ROLE];
            ev.event_type = m[slot_base + EV_SLOT_OFF_EVENT_TYPE];
            ev.flags = std.mem.readInt(u32, m[slot_base + EV_SLOT_OFF_FLAGS ..][0..4], .little);
            @memcpy(&ev.payload, m[slot_base + EV_SLOT_OFF_PAYLOAD ..][0..32]);

            const seq2 = @atomicLoad(u64, seq_ptr, .seq_cst);
            if (seq2 != next) {
                std.atomic.spinLoopHint();
                continue;
            }

            out[consumed] = ev;
            consumed += 1;
            self.last_consumed = next;
        }

        return .{ .events_consumed = consumed, .overrun = overrun };
    }
};

// ============================================================================
// Focus region constants and layout
// ============================================================================
//
// Region:   /var/run/sema/input/focus
// Total:    5,184 bytes (header 64 + 256 surface entries * 20 bytes)
// Spec:     shared/INPUT_FOCUS.md

pub const FOCUS_PATH = "/var/run/sema/input/focus";
pub const FOCUS_MAGIC: u32 = 0x4946434F; // "IFCO"
pub const FOCUS_VERSION: u8 = 1;
pub const FOCUS_HEADER_SIZE: usize = 64;
pub const FOCUS_SURFACE_SLOT_SIZE: usize = 20;
pub const FOCUS_SURFACE_SLOT_COUNT: u16 = 256;
pub const FOCUS_SIZE: usize =
    FOCUS_HEADER_SIZE + FOCUS_SURFACE_SLOT_COUNT * FOCUS_SURFACE_SLOT_SIZE;

pub const NO_FOCUS: u32 = 0;
pub const NO_GRAB: u32 = 0;

const FOCUS_OFF_MAGIC: usize = 0;
const FOCUS_OFF_VERSION: usize = 4;
const FOCUS_OFF_VALID: usize = 5;
const FOCUS_OFF_SLOT_COUNT: usize = 6;
const FOCUS_OFF_SEQLOCK: usize = 8;
const FOCUS_OFF_KB_FOCUS: usize = 12;
const FOCUS_OFF_PTR_GRAB: usize = 16;
const FOCUS_OFF_SURFACE_COUNT: usize = 20;

const FS_OFF_SESSION_ID: usize = 0;
const FS_OFF_X: usize = 4;
const FS_OFF_Y: usize = 8;
const FS_OFF_WIDTH: usize = 12;
const FS_OFF_HEIGHT: usize = 16;

pub const Surface = struct {
    session_id: u32,
    x: i32,
    y: i32,
    width: u32,
    height: u32,
};

pub const FocusSnapshot = struct {
    keyboard_focus: u32,
    pointer_grab: u32,
    surface_count: u16,
    surfaces: [FOCUS_SURFACE_SLOT_COUNT]Surface,

    /// Resolve which session should receive a pointer event at (px, py).
    /// Returns pointer_grab if a grab is active; otherwise scans the
    /// surface map top-down and returns the first session whose rectangle
    /// contains the cursor; otherwise null.
    pub fn resolvePointer(self: FocusSnapshot, px: i32, py: i32) ?u32 {
        if (self.pointer_grab != NO_GRAB) return self.pointer_grab;
        var i: usize = 0;
        while (i < self.surface_count) : (i += 1) {
            const s = self.surfaces[i];
            const right = s.x + @as(i32, @intCast(s.width));
            const bottom = s.y + @as(i32, @intCast(s.height));
            if (px >= s.x and px < right and py >= s.y and py < bottom) {
                return s.session_id;
            }
        }
        return null;
    }
};

// ============================================================================
// FocusWriter (compositor)
// ============================================================================

pub const FocusWriter = struct {
    map: []u8,
    fd: posix.fd_t,

    pub fn init(path: []const u8) !FocusWriter {
        try ensureParents(path);

        // Mode 0o600 per ADR 0013; operators relax via daemon's
        // process group and umask, not code.
        const raw_fd = try openCreateRdwr(path, 0o600);
        errdefer _ = posix.system.close(raw_fd);

        if (posix.system.ftruncate(raw_fd, @intCast(FOCUS_SIZE)) != 0) return error.TruncateFailed;

        const map_raw = try posix.mmap(
            null,
            FOCUS_SIZE,
            .{ .READ = true, .WRITE = true },
            .{ .TYPE = .SHARED },
            raw_fd,
            0,
        );
        errdefer posix.munmap(map_raw);

        const map: []u8 = map_raw[0..FOCUS_SIZE];
        @memset(map, 0);

        const writer = FocusWriter{ .map = map, .fd = raw_fd };

        writeU32(map, FOCUS_OFF_MAGIC, FOCUS_MAGIC);
        map[FOCUS_OFF_VERSION] = FOCUS_VERSION;
        map[FOCUS_OFF_VALID] = 0;
        writeU16(map, FOCUS_OFF_SLOT_COUNT, FOCUS_SURFACE_SLOT_COUNT);
        writeU32(map, FOCUS_OFF_SEQLOCK, 0);
        writeU32(map, FOCUS_OFF_KB_FOCUS, NO_FOCUS);
        writeU32(map, FOCUS_OFF_PTR_GRAB, NO_GRAB);
        writeU16(map, FOCUS_OFF_SURFACE_COUNT, 0);

        return writer;
    }

    pub fn deinit(self: FocusWriter) void {
        posix.munmap(@alignCast(self.map));
        _ = posix.system.close(self.fd);
    }

    pub fn markValid(self: FocusWriter) void {
        @atomicStore(u8, &self.map[FOCUS_OFF_VALID], 1, .seq_cst);
    }

    pub fn beginUpdate(self: FocusWriter) void {
        const ptr = atomicU32Ptr(self.map, FOCUS_OFF_SEQLOCK);
        const cur = @atomicLoad(u32, ptr, .seq_cst);
        @atomicStore(u32, ptr, cur + 1, .seq_cst);
    }

    pub fn endUpdate(self: FocusWriter) void {
        const ptr = atomicU32Ptr(self.map, FOCUS_OFF_SEQLOCK);
        const cur = @atomicLoad(u32, ptr, .seq_cst);
        @atomicStore(u32, ptr, cur + 1, .seq_cst);
    }

    pub fn setKeyboardFocus(self: FocusWriter, session_id: u32) void {
        writeU32(self.map, FOCUS_OFF_KB_FOCUS, session_id);
    }

    pub fn setPointerGrab(self: FocusWriter, session_id: u32) void {
        writeU32(self.map, FOCUS_OFF_PTR_GRAB, session_id);
    }

    /// Replace the surface map. `surfaces` is in top-to-bottom z-order.
    /// Surfaces beyond FOCUS_SURFACE_SLOT_COUNT are dropped per
    /// INPUT_FOCUS.md "Failure modes".
    pub fn setSurfaceMap(self: FocusWriter, surfaces: []const Surface) void {
        const n = @min(surfaces.len, FOCUS_SURFACE_SLOT_COUNT);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const off = FOCUS_HEADER_SIZE + i * FOCUS_SURFACE_SLOT_SIZE;
            writeU32(self.map, off + FS_OFF_SESSION_ID, surfaces[i].session_id);
            writeI32(self.map, off + FS_OFF_X, surfaces[i].x);
            writeI32(self.map, off + FS_OFF_Y, surfaces[i].y);
            writeU32(self.map, off + FS_OFF_WIDTH, surfaces[i].width);
            writeU32(self.map, off + FS_OFF_HEIGHT, surfaces[i].height);
        }
        while (i < FOCUS_SURFACE_SLOT_COUNT) : (i += 1) {
            const off = FOCUS_HEADER_SIZE + i * FOCUS_SURFACE_SLOT_SIZE;
            @memset(self.map[off..][0..FOCUS_SURFACE_SLOT_SIZE], 0);
        }
        writeU16(self.map, FOCUS_OFF_SURFACE_COUNT, @intCast(n));
    }
};

// ============================================================================
// FocusReader (kernel side; modeled in userspace for tests)
// ============================================================================

pub const FocusReader = struct {
    map: ?[]const u8,
    fd: posix.fd_t,

    pub fn init(path: []const u8) FocusReader {
        const raw_fd = openReadOnly(path) catch {
            return .{ .map = null, .fd = -1 };
        };

        // Defensive size check before mmap. See StateReader.init.
        const end_pos = fileSize(raw_fd) catch {
            _ = posix.system.close(raw_fd);
            return .{ .map = null, .fd = -1 };
        };
        if (end_pos < @as(u64, FOCUS_SIZE)) {
            _ = posix.system.close(raw_fd);
            return .{ .map = null, .fd = -1 };
        }

        const map_raw = posix.mmap(
            null,
            FOCUS_SIZE,
            .{ .READ = true },
            .{ .TYPE = .SHARED },
            raw_fd,
            0,
        ) catch {
            _ = posix.system.close(raw_fd);
            return .{ .map = null, .fd = -1 };
        };

        const map: []const u8 = map_raw[0..FOCUS_SIZE];
        const magic = std.mem.readInt(u32, map[FOCUS_OFF_MAGIC..][0..4], .little);
        if (magic != FOCUS_MAGIC or map[FOCUS_OFF_VERSION] != FOCUS_VERSION) {
            posix.munmap(@alignCast(map_raw));
            _ = posix.system.close(raw_fd);
            return .{ .map = null, .fd = -1 };
        }

        return .{ .map = map, .fd = raw_fd };
    }

    pub fn deinit(self: FocusReader) void {
        if (self.map) |m| posix.munmap(@alignCast(@constCast(m)));
        if (self.fd >= 0) _ = posix.system.close(self.fd);
    }

    pub fn isValid(self: FocusReader) bool {
        const m = self.map orelse return false;
        return @atomicLoad(u8, &m[FOCUS_OFF_VALID], .seq_cst) != 0;
    }

    pub fn snapshot(self: FocusReader) !FocusSnapshot {
        const m = self.map orelse return error.NotOpen;
        const seqlock_ptr = atomicU32PtrConst(m, FOCUS_OFF_SEQLOCK);

        var attempt: usize = 0;
        const MAX_ATTEMPTS: usize = 1024;
        while (attempt < MAX_ATTEMPTS) : (attempt += 1) {
            const v1 = @atomicLoad(u32, seqlock_ptr, .seq_cst);
            if (v1 & 1 != 0) {
                std.atomic.spinLoopHint();
                continue;
            }

            var snap: FocusSnapshot = undefined;
            snap.keyboard_focus = std.mem.readInt(u32, m[FOCUS_OFF_KB_FOCUS..][0..4], .little);
            snap.pointer_grab = std.mem.readInt(u32, m[FOCUS_OFF_PTR_GRAB..][0..4], .little);
            snap.surface_count = std.mem.readInt(u16, m[FOCUS_OFF_SURFACE_COUNT..][0..2], .little);

            var i: usize = 0;
            while (i < FOCUS_SURFACE_SLOT_COUNT) : (i += 1) {
                const off = FOCUS_HEADER_SIZE + i * FOCUS_SURFACE_SLOT_SIZE;
                snap.surfaces[i] = .{
                    .session_id = std.mem.readInt(u32, m[off + FS_OFF_SESSION_ID ..][0..4], .little),
                    .x = std.mem.readInt(i32, m[off + FS_OFF_X ..][0..4], .little),
                    .y = std.mem.readInt(i32, m[off + FS_OFF_Y ..][0..4], .little),
                    .width = std.mem.readInt(u32, m[off + FS_OFF_WIDTH ..][0..4], .little),
                    .height = std.mem.readInt(u32, m[off + FS_OFF_HEIGHT ..][0..4], .little),
                };
            }

            const v2 = @atomicLoad(u32, seqlock_ptr, .seq_cst);
            if (v2 == v1) return snap;
        }
        return error.SeqlockContended;
    }
};

// ============================================================================
// Smoothing region constants and layout
// ============================================================================
//
// Region:   /var/run/sema/input/smoothing
// Total:    32 bytes (header 12 + parameter block 20)
// Spec:     shared/INPUT_SMOOTHING.md
// ADR:      inputfs/docs/adr/0015-per-user-pointer-smoothing.md
//
// Compositor-written, kernel-read. Mirrors the focus region's
// publication shape: semadrawd creates the file at startup,
// publishes parameters under a seqlock, and the inputfs kernel
// module reads the cached buffer on each pointer event between
// the D.3 transform and D.4 routing steps. With the region
// absent or smoothing_valid == 0, inputfs falls back to identity
// (SMOOTHING_NONE), so smoothing is strictly additive: behaviour
// without a publishing compositor matches Stage D as it landed.

pub const SMOOTHING_PATH = "/var/run/sema/input/smoothing";
pub const SMOOTHING_MAGIC: u32 = 0x494E534D; // "INSM"
pub const SMOOTHING_VERSION: u8 = 1;
pub const SMOOTHING_HEADER_SIZE: usize = 12;
pub const SMOOTHING_PARAMS_SIZE: usize = 20;
pub const SMOOTHING_SIZE: usize =
    SMOOTHING_HEADER_SIZE + SMOOTHING_PARAMS_SIZE;

// Algorithm enum values per INPUT_SMOOTHING.md.
pub const SMOOTHING_NONE: u8 = 0;
pub const SMOOTHING_EMA: u8 = 1;
pub const SMOOTHING_ONE_EURO: u8 = 2;

// Q16.16 fixed-point constants.
pub const Q16_ONE: i32 = 0x10000;

// EMA defaults and valid range per INPUT_SMOOTHING.md.
// Note: EMA_ALPHA_MAX = 0xFF34 fits in 16 bits unsigned and is a
// small positive i32; the signed type is for arithmetic
// uniformity with the Q16.16 representation of the other params.
pub const EMA_DEFAULT_ALPHA: i32 = 0x4CCC; // ~0.30
pub const EMA_ALPHA_MIN: i32 = 0x00CC;     // ~0.005
pub const EMA_ALPHA_MAX: i32 = 0xFF34;     // ~0.995

// One-Euro defaults per INPUT_SMOOTHING.md.
pub const ONE_EURO_DEFAULT_MIN_CUTOFF: i32 = 0x10000; // 1.0 Hz
pub const ONE_EURO_DEFAULT_BETA: i32 = 0x01CB;        // ~0.007
pub const ONE_EURO_DEFAULT_D_CUTOFF: i32 = 0x10000;   // 1.0 Hz

// Header offsets per INPUT_SMOOTHING.md.
const SM_OFF_MAGIC: usize = 0;
const SM_OFF_VERSION: usize = 4;
const SM_OFF_ALGORITHM: usize = 5;
const SM_OFF_VALID: usize = 6;
const SM_OFF_PAD0: usize = 7;
const SM_OFF_SEQLOCK: usize = 8;
const SM_OFF_PARAMS: usize = 12;

// Parameter offsets relative to SM_OFF_PARAMS, per algorithm.
// EMA uses the first 4 bytes; remainder is _pad zeros.
const SM_PARAM_EMA_ALPHA: usize = 0;
// One-Euro uses the first 12 bytes; remainder is _pad zeros.
const SM_PARAM_OE_MIN_CUTOFF: usize = 0;
const SM_PARAM_OE_BETA: usize = 4;
const SM_PARAM_OE_D_CUTOFF: usize = 8;

/// SmoothingSnapshot is the flat, by-value snapshot returned by
/// SmoothingReader.snapshot(). Only fields meaningful to the
/// current algorithm are populated:
///   - SMOOTHING_NONE: only `algorithm` is meaningful.
///   - SMOOTHING_EMA: `algorithm` and `alpha`.
///   - SMOOTHING_ONE_EURO: `algorithm`, `min_cutoff`, `beta`, `d_cutoff`.
/// All Q16.16 fields decode directly to i32. The kernel-side
/// reader has its own analogous struct in inputfs.c.
pub const SmoothingSnapshot = struct {
    algorithm: u8,
    alpha: i32,
    min_cutoff: i32,
    beta: i32,
    d_cutoff: i32,
};

// ============================================================================
// SmoothingWriter (compositor)
// ============================================================================

pub const SmoothingWriter = struct {
    map: []u8,
    fd: posix.fd_t,

    pub fn init(path: []const u8) !SmoothingWriter {
        try ensureParents(path);

        // Mode 0o600 per ADR 0013; same rationale as FocusWriter.
        const raw_fd = try openCreateRdwr(path, 0o600);
        errdefer _ = posix.system.close(raw_fd);

        if (posix.system.ftruncate(raw_fd, @intCast(SMOOTHING_SIZE)) != 0) return error.TruncateFailed;

        const map_raw = try posix.mmap(
            null,
            SMOOTHING_SIZE,
            .{ .READ = true, .WRITE = true },
            .{ .TYPE = .SHARED },
            raw_fd,
            0,
        );
        errdefer posix.munmap(map_raw);

        const map: []u8 = map_raw[0..SMOOTHING_SIZE];
        @memset(map, 0);

        const writer = SmoothingWriter{ .map = map, .fd = raw_fd };

        writeU32(map, SM_OFF_MAGIC, SMOOTHING_MAGIC);
        map[SM_OFF_VERSION] = SMOOTHING_VERSION;
        map[SM_OFF_ALGORITHM] = SMOOTHING_NONE;
        map[SM_OFF_VALID] = 0;
        writeU32(map, SM_OFF_SEQLOCK, 0);
        // Parameter block already zeroed by @memset above.

        return writer;
    }

    pub fn deinit(self: SmoothingWriter) void {
        posix.munmap(@alignCast(self.map));
        _ = posix.system.close(self.fd);
    }

    pub fn markValid(self: SmoothingWriter) void {
        @atomicStore(u8, &self.map[SM_OFF_VALID], 1, .seq_cst);
    }

    pub fn beginUpdate(self: SmoothingWriter) void {
        const ptr = atomicU32Ptr(self.map, SM_OFF_SEQLOCK);
        const cur = @atomicLoad(u32, ptr, .seq_cst);
        @atomicStore(u32, ptr, cur + 1, .seq_cst);
    }

    pub fn endUpdate(self: SmoothingWriter) void {
        const ptr = atomicU32Ptr(self.map, SM_OFF_SEQLOCK);
        const cur = @atomicLoad(u32, ptr, .seq_cst);
        @atomicStore(u32, ptr, cur + 1, .seq_cst);
    }

    /// Switch to identity (no smoothing). Zeroes the parameter
    /// block per INPUT_SMOOTHING.md "All 20 bytes zero-filled".
    pub fn setNone(self: SmoothingWriter) void {
        self.map[SM_OFF_ALGORITHM] = SMOOTHING_NONE;
        @memset(self.map[SM_OFF_PARAMS..][0..SMOOTHING_PARAMS_SIZE], 0);
    }

    /// Switch to EMA with the given alpha (Q16.16). Bytes beyond
    /// alpha (16 of 20 in the parameter block) are zero-filled
    /// per spec.
    pub fn setEma(self: SmoothingWriter, alpha: i32) void {
        self.map[SM_OFF_ALGORITHM] = SMOOTHING_EMA;
        @memset(self.map[SM_OFF_PARAMS..][0..SMOOTHING_PARAMS_SIZE], 0);
        writeI32(self.map, SM_OFF_PARAMS + SM_PARAM_EMA_ALPHA, alpha);
    }

    /// Switch to One-Euro with the given parameters (all Q16.16).
    /// Bytes beyond the three params (8 of 20) are zero-filled.
    pub fn setOneEuro(
        self: SmoothingWriter,
        min_cutoff: i32,
        beta: i32,
        d_cutoff: i32,
    ) void {
        self.map[SM_OFF_ALGORITHM] = SMOOTHING_ONE_EURO;
        @memset(self.map[SM_OFF_PARAMS..][0..SMOOTHING_PARAMS_SIZE], 0);
        writeI32(self.map, SM_OFF_PARAMS + SM_PARAM_OE_MIN_CUTOFF, min_cutoff);
        writeI32(self.map, SM_OFF_PARAMS + SM_PARAM_OE_BETA, beta);
        writeI32(self.map, SM_OFF_PARAMS + SM_PARAM_OE_D_CUTOFF, d_cutoff);
    }
};

// ============================================================================
// SmoothingReader (kernel side; modeled in userspace for tests and tooling)
// ============================================================================

pub const SmoothingReader = struct {
    map: ?[]const u8,
    fd: posix.fd_t,

    pub fn init(path: []const u8) SmoothingReader {
        const raw_fd = openReadOnly(path) catch {
            return .{ .map = null, .fd = -1 };
        };

        const end_pos = fileSize(raw_fd) catch {
            _ = posix.system.close(raw_fd);
            return .{ .map = null, .fd = -1 };
        };
        if (end_pos < @as(u64, SMOOTHING_SIZE)) {
            _ = posix.system.close(raw_fd);
            return .{ .map = null, .fd = -1 };
        }

        const map_raw = posix.mmap(
            null,
            SMOOTHING_SIZE,
            .{ .READ = true },
            .{ .TYPE = .SHARED },
            raw_fd,
            0,
        ) catch {
            _ = posix.system.close(raw_fd);
            return .{ .map = null, .fd = -1 };
        };

        const map: []const u8 = map_raw[0..SMOOTHING_SIZE];
        const magic = std.mem.readInt(u32, map[SM_OFF_MAGIC..][0..4], .little);
        if (magic != SMOOTHING_MAGIC or map[SM_OFF_VERSION] != SMOOTHING_VERSION) {
            posix.munmap(@alignCast(map_raw));
            _ = posix.system.close(raw_fd);
            return .{ .map = null, .fd = -1 };
        }

        return .{ .map = map, .fd = raw_fd };
    }

    pub fn deinit(self: SmoothingReader) void {
        if (self.map) |m| posix.munmap(@alignCast(@constCast(m)));
        if (self.fd >= 0) _ = posix.system.close(self.fd);
    }

    pub fn isValid(self: SmoothingReader) bool {
        const m = self.map orelse return false;
        return @atomicLoad(u8, &m[SM_OFF_VALID], .seq_cst) != 0;
    }

    /// Snapshot the smoothing region under a seqlock retry loop.
    /// Only fields meaningful to `algorithm` are populated;
    /// others are zero. Consumers dispatch on `algorithm` and
    /// read the corresponding fields.
    pub fn snapshot(self: SmoothingReader) !SmoothingSnapshot {
        const m = self.map orelse return error.NotOpen;
        const seqlock_ptr = atomicU32PtrConst(m, SM_OFF_SEQLOCK);

        var attempt: usize = 0;
        const MAX_ATTEMPTS: usize = 1024;
        while (attempt < MAX_ATTEMPTS) : (attempt += 1) {
            const v1 = @atomicLoad(u32, seqlock_ptr, .seq_cst);
            if (v1 & 1 != 0) {
                std.atomic.spinLoopHint();
                continue;
            }

            var snap: SmoothingSnapshot = .{
                .algorithm = m[SM_OFF_ALGORITHM],
                .alpha = 0,
                .min_cutoff = 0,
                .beta = 0,
                .d_cutoff = 0,
            };
            switch (snap.algorithm) {
                SMOOTHING_NONE => {},
                SMOOTHING_EMA => {
                    snap.alpha = std.mem.readInt(
                        i32,
                        m[SM_OFF_PARAMS + SM_PARAM_EMA_ALPHA ..][0..4],
                        .little,
                    );
                },
                SMOOTHING_ONE_EURO => {
                    snap.min_cutoff = std.mem.readInt(
                        i32,
                        m[SM_OFF_PARAMS + SM_PARAM_OE_MIN_CUTOFF ..][0..4],
                        .little,
                    );
                    snap.beta = std.mem.readInt(
                        i32,
                        m[SM_OFF_PARAMS + SM_PARAM_OE_BETA ..][0..4],
                        .little,
                    );
                    snap.d_cutoff = std.mem.readInt(
                        i32,
                        m[SM_OFF_PARAMS + SM_PARAM_OE_D_CUTOFF ..][0..4],
                        .little,
                    );
                },
                else => {
                    // Unknown algorithm: snapshot reports it as-is;
                    // consumer is expected to fall back to identity
                    // per INPUT_SMOOTHING.md "Failure modes".
                },
            }

            const v2 = @atomicLoad(u32, seqlock_ptr, .seq_cst);
            if (v2 == v1) return snap;
        }
        return error.SeqlockContended;
    }
};

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

// Test-only raw-posix fixture helpers. The tests exercise production code that
// sits on posix.system plus mmap (ADR shared 0001), so fixtures use the same
// primitives rather than threading an Io handle through std.Io.File. The one
// std.Io call retained is tmp.dir.realPath: there is no raw-posix way to resolve
// a TmpDir's path.
fn testCreateWrite(path: []const u8, bytes: []const u8) !void {
    const fd = try openCreateRdwr(path, 0o600);
    defer _ = posix.system.close(fd);
    if (bytes.len > 0) _ = posix.system.write(fd, bytes.ptr, bytes.len);
}

fn testFileSize(path: []const u8) !u64 {
    const fd = try openReadOnly(path);
    defer _ = posix.system.close(fd);
    return fileSize(fd);
}

fn testRemove(path: []const u8) !void {
    var pz = try posix.toPosixPath(path);
    _ = posix.system.unlink(&pz);
}

fn testExists(path: []const u8) bool {
    const fd = openReadOnly(path) catch return false;
    _ = posix.system.close(fd);
    return true;
}

fn tmpStatePath(tmp: *std.testing.TmpDir, buf: []u8) ![]u8 {
    var p_buf: [std.fs.max_path_bytes]u8 = undefined;
    var io_backing = std.Io.Threaded.init(std.testing.allocator, .{});
    defer io_backing.deinit();
    const io = io_backing.io();
    const p_len = try tmp.dir.realPath(io, &p_buf);
    const p = p_buf[0..p_len];
    return std.fmt.bufPrint(buf, "{s}/state", .{p});
}

fn tmpEventsPath(tmp: *std.testing.TmpDir, buf: []u8) ![]u8 {
    var p_buf: [std.fs.max_path_bytes]u8 = undefined;
    var io_backing = std.Io.Threaded.init(std.testing.allocator, .{});
    defer io_backing.deinit();
    const io = io_backing.io();
    const p_len = try tmp.dir.realPath(io, &p_buf);
    const p = p_buf[0..p_len];
    return std.fmt.bufPrint(buf, "{s}/events", .{p});
}

fn tmpFocusPath(tmp: *std.testing.TmpDir, buf: []u8) ![]u8 {
    var p_buf: [std.fs.max_path_bytes]u8 = undefined;
    var io_backing = std.Io.Threaded.init(std.testing.allocator, .{});
    defer io_backing.deinit();
    const io = io_backing.io();
    const p_len = try tmp.dir.realPath(io, &p_buf);
    const p = p_buf[0..p_len];
    return std.fmt.bufPrint(buf, "{s}/focus", .{p});
}

fn tmpSmoothingPath(tmp: *std.testing.TmpDir, buf: []u8) ![]u8 {
    var p_buf: [std.fs.max_path_bytes]u8 = undefined;
    var io_backing = std.Io.Threaded.init(std.testing.allocator, .{});
    defer io_backing.deinit();
    const io = io_backing.io();
    const p_len = try tmp.dir.realPath(io, &p_buf);
    const p = p_buf[0..p_len];
    return std.fmt.bufPrint(buf, "{s}/smoothing", .{p});
}

test "STATE_SIZE matches spec" {
    try testing.expectEqual(@as(usize, 11_328), STATE_SIZE);
}

test "EVENTS_SIZE matches spec" {
    try testing.expectEqual(@as(usize, 65_600), EVENTS_SIZE);
}

test "FOCUS_SIZE matches spec" {
    try testing.expectEqual(@as(usize, 5_184), FOCUS_SIZE);
}

test "SMOOTHING_SIZE matches spec" {
    try testing.expectEqual(@as(usize, 32), SMOOTHING_SIZE);
}

test "ensureParents creates nested missing directories" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var p_buf: [std.fs.max_path_bytes]u8 = undefined;
    var io_backing = std.Io.Threaded.init(std.testing.allocator, .{});
    defer io_backing.deinit();
    const io = io_backing.io();
    const tmp_len = try tmp.dir.realPath(io, &p_buf);
    const tmp_path = p_buf[0..tmp_len];
    var full_buf: [std.fs.max_path_bytes]u8 = undefined;
    const nested_path = try std.fmt.bufPrint(&full_buf, "{s}/a/b/c/file", .{tmp_path});

    try ensureParents(nested_path);

    // Confirm a/b/c exists.
    var abc_buf: [std.fs.max_path_bytes]u8 = undefined;
    const abc_path = try std.fmt.bufPrint(&abc_buf, "{s}/a/b/c", .{tmp_path});
    try testing.expect(testExists(abc_path));
}

test "state writer creates file at expected size" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try tmpStatePath(&tmp, &buf);

    var w = try StateWriter.init(path);
    defer w.deinit();

    const sz = try testFileSize(path);
    try testing.expectEqual(@as(u64, STATE_SIZE), sz);
}

test "state reader rejects absent file gracefully" {
    const r = StateReader.init("/var/run/sema/input/state_does_not_exist_test");
    defer r.deinit();
    try testing.expect(!r.isValid());
}

test "state reader rejects wrong magic" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try tmpStatePath(&tmp, &buf);

    try testCreateWrite(path, &[_]u8{0} ** STATE_SIZE);

    const r = StateReader.init(path);
    defer r.deinit();
    try testing.expect(!r.isValid());
}

test "state reader rejects truncated file (smaller than STATE_SIZE)" {
    // Regression test: a file shorter than STATE_SIZE, which can
    // briefly exist during semainputd's bringup window between
    // createFileAbsolute(.truncate=true) and setEndPos(STATE_SIZE).
    // Pre-fix, mmap would succeed and the magic-byte read at line 445
    // would SIGBUS/SIGSEGV; post-fix, init returns an empty reader.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try tmpStatePath(&tmp, &buf);

    // Zero-byte file (truncate but no setEndPos).
    try testCreateWrite(path, &[_]u8{});

    const r0 = StateReader.init(path);
    defer r0.deinit();
    try testing.expect(!r0.isValid());
    try testing.expect(r0.map == null);
    try testing.expect(r0.fd == -1);

    // Partial file: some bytes, but less than STATE_SIZE.
    try testRemove(path);
    try testCreateWrite(path, &[_]u8{0} ** 100);

    const r1 = StateReader.init(path);
    defer r1.deinit();
    try testing.expect(!r1.isValid());
    try testing.expect(r1.map == null);
    try testing.expect(r1.fd == -1);

    // Exactly STATE_SIZE - 1 bytes: still rejected.
    try testRemove(path);
    try testCreateWrite(path, &[_]u8{0} ** (STATE_SIZE - 1));

    const r2 = StateReader.init(path);
    defer r2.deinit();
    try testing.expect(!r2.isValid());
}

test "state writer/reader pointer round-trip under seqlock" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try tmpStatePath(&tmp, &buf);

    var w = try StateWriter.init(path);
    defer w.deinit();

    const r = StateReader.init(path);
    defer r.deinit();

    try testing.expect(!r.isValid());

    w.beginUpdate();
    w.setPointer(.{ .x = 100, .y = 200, .buttons = 0b011 });
    w.setLastSequence(42);
    w.endUpdate();
    w.markValid();

    try testing.expect(r.isValid());
    const snap = try r.snapshot();
    try testing.expectEqual(@as(i32, 100), snap.pointer_x);
    try testing.expectEqual(@as(i32, 200), snap.pointer_y);
    try testing.expectEqual(@as(u32, 0b011), snap.pointer_buttons);
    try testing.expectEqual(@as(u64, 42), snap.last_sequence);
}

test "state transform_active defaults to zero (Stage C semantics)" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try tmpStatePath(&tmp, &buf);

    var w = try StateWriter.init(path);
    defer w.deinit();

    const r = StateReader.init(path);
    defer r.deinit();

    w.markValid();
    const snap = try r.snapshot();
    try testing.expectEqual(@as(u8, 0), snap.transform_active);
}

test "state transform_active round-trip (Stage D semantics)" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try tmpStatePath(&tmp, &buf);

    var w = try StateWriter.init(path);
    defer w.deinit();

    const r = StateReader.init(path);
    defer r.deinit();

    w.beginUpdate();
    w.setTransformActive(1);
    w.endUpdate();
    w.markValid();

    const snap = try r.snapshot();
    try testing.expectEqual(@as(u8, 1), snap.transform_active);
}

test "state writer/reader device round-trip" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try tmpStatePath(&tmp, &buf);

    var w = try StateWriter.init(path);
    defer w.deinit();
    const r = StateReader.init(path);
    defer r.deinit();

    var dev: DeviceDescriptor = undefined;
    @memset(&dev.device_id, 0);
    dev.device_id[0] = 0xAB;
    dev.device_id[15] = 0xCD;
    @memset(&dev.identity_hash, 0xEE);
    dev.roles = ROLE_POINTER | ROLE_LIGHTING;
    dev.usb_vendor = 0x056e;
    dev.usb_product = 0x00e3;
    @memset(&dev.name, 0);
    @memcpy(dev.name[0..20], "ELECOM BlueLED Mouse");
    dev.lighting_caps.zone_count = 2;
    dev.lighting_caps.flags = 0;
    @memset(&dev.lighting_caps.zones, .{ .type = 0, .sub_zone_count = 0 });
    dev.lighting_caps.zones[0] = .{ .type = 3, .sub_zone_count = 1 };
    dev.lighting_caps.zones[1] = .{ .type = 1, .sub_zone_count = 1 };

    w.beginUpdate();
    try w.putDevice(7, dev);
    w.setDeviceCount(1);
    w.endUpdate();
    w.markValid();

    const snap = try r.snapshot();
    try testing.expectEqual(@as(u16, 1), snap.device_count);
    const got = snap.devices[7];
    try testing.expectEqual(@as(u8, 0xAB), got.device_id[0]);
    try testing.expectEqual(@as(u8, 0xCD), got.device_id[15]);
    try testing.expectEqual(@as(u32, ROLE_POINTER | ROLE_LIGHTING), got.roles);
    try testing.expectEqual(@as(u16, 0x056e), got.usb_vendor);
    try testing.expectEqual(@as(u16, 0x00e3), got.usb_product);
    try testing.expectEqualStrings("ELECOM BlueLED Mouse", got.name[0..20]);
    try testing.expectEqual(@as(u8, 2), got.lighting_caps.zone_count);
    try testing.expectEqual(@as(u8, 3), got.lighting_caps.zones[0].type);
}

test "state slot out of range" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try tmpStatePath(&tmp, &buf);

    var w = try StateWriter.init(path);
    defer w.deinit();
    const empty: DeviceDescriptor = std.mem.zeroes(DeviceDescriptor);
    try testing.expectError(error.SlotOutOfRange, w.putDevice(STATE_SLOT_COUNT, empty));
    try testing.expectError(error.SlotOutOfRange, w.clearDevice(STATE_SLOT_COUNT));
}

test "events writer creates file at expected size" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try tmpEventsPath(&tmp, &buf);

    var w = try EventRingWriter.init(path);
    defer w.deinit();

    const sz = try testFileSize(path);
    try testing.expectEqual(@as(u64, EVENTS_SIZE), sz);
}

test "events writer/reader single publish drains" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try tmpEventsPath(&tmp, &buf);

    var w = try EventRingWriter.init(path);
    defer w.deinit();
    var r = EventRingReader.init(path);
    defer r.deinit();

    w.markValid();
    try testing.expect(r.isValid());

    var payload: [32]u8 = undefined;
    @memset(&payload, 0);
    std.mem.writeInt(i32, payload[0..4], 1024, .little);
    std.mem.writeInt(i32, payload[4..8], 512, .little);
    std.mem.writeInt(i32, payload[8..12], 1, .little);
    std.mem.writeInt(i32, payload[12..16], 0, .little);

    w.publish(.{
        .seq = 0,
        .ts_ordering = 1_000_000,
        .ts_sync = 0,
        .device_slot = 3,
        .source_role = SOURCE_POINTER,
        .event_type = 1,
        .flags = 0,
        .payload = payload,
    });

    var out: [10]Event = undefined;
    const result = try r.drain(&out);
    try testing.expectEqual(@as(usize, 1), result.events_consumed);
    try testing.expect(!result.overrun);
    try testing.expectEqual(@as(u64, 1), out[0].seq);
    try testing.expectEqual(@as(u64, 1_000_000), out[0].ts_ordering);
    try testing.expectEqual(@as(u16, 3), out[0].device_slot);
    try testing.expectEqual(SOURCE_POINTER, out[0].source_role);
    try testing.expectEqual(@as(u8, 1), out[0].event_type);
    try testing.expectEqual(@as(i32, 1024), std.mem.readInt(i32, out[0].payload[0..4], .little));
}

test "events drain in order across many publishes" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try tmpEventsPath(&tmp, &buf);

    var w = try EventRingWriter.init(path);
    defer w.deinit();
    var r = EventRingReader.init(path);
    defer r.deinit();

    var payload: [32]u8 = undefined;
    @memset(&payload, 0);

    var i: u64 = 0;
    while (i < 100) : (i += 1) {
        w.publish(.{
            .seq = 0,
            .ts_ordering = i * 1_000,
            .ts_sync = 0,
            .device_slot = 0,
            .source_role = SOURCE_POINTER,
            .event_type = 1,
            .flags = 0,
            .payload = payload,
        });
    }

    var out: [200]Event = undefined;
    const result = try r.drain(&out);
    try testing.expectEqual(@as(usize, 100), result.events_consumed);
    try testing.expect(!result.overrun);
    var j: usize = 0;
    while (j < 100) : (j += 1) {
        try testing.expectEqual(@as(u64, j + 1), out[j].seq);
        try testing.expectEqual(@as(u64, j * 1_000), out[j].ts_ordering);
    }
}

test "events ring overrun detected on slow consumer" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try tmpEventsPath(&tmp, &buf);

    var w = try EventRingWriter.init(path);
    defer w.deinit();
    var r = EventRingReader.init(path);
    defer r.deinit();

    var payload: [32]u8 = undefined;
    @memset(&payload, 0);

    // Publish past one full ring without draining; earliest_seq should advance.
    var i: u64 = 0;
    while (i < EVENTS_SLOT_COUNT + 100) : (i += 1) {
        w.publish(.{
            .seq = 0,
            .ts_ordering = i,
            .ts_sync = 0,
            .device_slot = 0,
            .source_role = SOURCE_POINTER,
            .event_type = 1,
            .flags = 0,
            .payload = payload,
        });
    }

    try testing.expect(r.earliestSeq() > 1);

    var out: [200]Event = undefined;
    const result = try r.drain(&out);
    try testing.expect(result.overrun);
    try testing.expect(result.events_consumed > 0);
}

test "focus writer creates file at expected size" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try tmpFocusPath(&tmp, &buf);

    var w = try FocusWriter.init(path);
    defer w.deinit();

    const sz = try testFileSize(path);
    try testing.expectEqual(@as(u64, FOCUS_SIZE), sz);
}

test "focus writer/reader round-trip with surface map" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try tmpFocusPath(&tmp, &buf);

    var w = try FocusWriter.init(path);
    defer w.deinit();
    const r = FocusReader.init(path);
    defer r.deinit();

    const surfaces = [_]Surface{
        .{ .session_id = 1, .x = 0, .y = 0, .width = 800, .height = 600 },
        .{ .session_id = 2, .x = 100, .y = 100, .width = 400, .height = 300 },
        .{ .session_id = 3, .x = 200, .y = 200, .width = 100, .height = 100 },
    };

    w.beginUpdate();
    w.setKeyboardFocus(2);
    w.setPointerGrab(NO_GRAB);
    w.setSurfaceMap(&surfaces);
    w.endUpdate();
    w.markValid();

    try testing.expect(r.isValid());
    const snap = try r.snapshot();
    try testing.expectEqual(@as(u32, 2), snap.keyboard_focus);
    try testing.expectEqual(@as(u32, NO_GRAB), snap.pointer_grab);
    try testing.expectEqual(@as(u16, 3), snap.surface_count);
    try testing.expectEqual(@as(u32, 1), snap.surfaces[0].session_id);
    try testing.expectEqual(@as(u32, 800), snap.surfaces[0].width);
}

test "focus resolvePointer respects grab" {
    var snap: FocusSnapshot = undefined;
    snap.keyboard_focus = NO_FOCUS;
    snap.pointer_grab = 99;
    snap.surface_count = 0;
    @memset(&snap.surfaces, std.mem.zeroes(Surface));

    try testing.expectEqual(@as(?u32, 99), snap.resolvePointer(0, 0));
    try testing.expectEqual(@as(?u32, 99), snap.resolvePointer(10_000, 10_000));
}

test "focus resolvePointer returns top-most surface under cursor" {
    var snap: FocusSnapshot = undefined;
    snap.keyboard_focus = NO_FOCUS;
    snap.pointer_grab = NO_GRAB;
    snap.surface_count = 2;
    @memset(&snap.surfaces, std.mem.zeroes(Surface));
    snap.surfaces[0] = .{ .session_id = 7, .x = 100, .y = 100, .width = 50, .height = 50 };
    snap.surfaces[1] = .{ .session_id = 1, .x = 0, .y = 0, .width = 1000, .height = 1000 };

    try testing.expectEqual(@as(?u32, 7), snap.resolvePointer(120, 120));
    try testing.expectEqual(@as(?u32, 1), snap.resolvePointer(500, 500));
    try testing.expectEqual(@as(?u32, null), snap.resolvePointer(2000, 2000));
}

test "focus reader rejects absent file gracefully" {
    const r = FocusReader.init("/var/run/sema/input/focus_does_not_exist_test");
    defer r.deinit();
    try testing.expect(!r.isValid());
}

test "smoothing writer creates file at expected size" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try tmpSmoothingPath(&tmp, &buf);

    var w = try SmoothingWriter.init(path);
    defer w.deinit();

    const sz = try testFileSize(path);
    try testing.expectEqual(@as(u64, SMOOTHING_SIZE), sz);
}

test "smoothing reader returns invalid before markValid" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try tmpSmoothingPath(&tmp, &buf);

    var w = try SmoothingWriter.init(path);
    defer w.deinit();
    const r = SmoothingReader.init(path);
    defer r.deinit();

    // Writer initialised the region with smoothing_valid = 0;
    // reader should report not-valid. The compositor flips
    // valid → 1 only after publishing a coherent first snapshot.
    try testing.expect(!r.isValid());
}

test "smoothing writer/reader round-trip none" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try tmpSmoothingPath(&tmp, &buf);

    var w = try SmoothingWriter.init(path);
    defer w.deinit();
    const r = SmoothingReader.init(path);
    defer r.deinit();

    w.beginUpdate();
    w.setNone();
    w.endUpdate();
    w.markValid();

    try testing.expect(r.isValid());
    const snap = try r.snapshot();
    try testing.expectEqual(@as(u8, SMOOTHING_NONE), snap.algorithm);
    // Per spec, none uses zero parameter bytes; snapshot fields
    // for the disabled algorithms are zero.
    try testing.expectEqual(@as(i32, 0), snap.alpha);
    try testing.expectEqual(@as(i32, 0), snap.min_cutoff);
    try testing.expectEqual(@as(i32, 0), snap.beta);
    try testing.expectEqual(@as(i32, 0), snap.d_cutoff);
}

test "smoothing writer/reader round-trip ema" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try tmpSmoothingPath(&tmp, &buf);

    var w = try SmoothingWriter.init(path);
    defer w.deinit();
    const r = SmoothingReader.init(path);
    defer r.deinit();

    w.beginUpdate();
    w.setEma(EMA_DEFAULT_ALPHA);
    w.endUpdate();
    w.markValid();

    try testing.expect(r.isValid());
    const snap = try r.snapshot();
    try testing.expectEqual(@as(u8, SMOOTHING_EMA), snap.algorithm);
    try testing.expectEqual(EMA_DEFAULT_ALPHA, snap.alpha);
    // One-Euro fields are not populated when algorithm is EMA.
    try testing.expectEqual(@as(i32, 0), snap.min_cutoff);
    try testing.expectEqual(@as(i32, 0), snap.beta);
    try testing.expectEqual(@as(i32, 0), snap.d_cutoff);
}

test "smoothing writer/reader round-trip one_euro" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try tmpSmoothingPath(&tmp, &buf);

    var w = try SmoothingWriter.init(path);
    defer w.deinit();
    const r = SmoothingReader.init(path);
    defer r.deinit();

    w.beginUpdate();
    w.setOneEuro(
        ONE_EURO_DEFAULT_MIN_CUTOFF,
        ONE_EURO_DEFAULT_BETA,
        ONE_EURO_DEFAULT_D_CUTOFF,
    );
    w.endUpdate();
    w.markValid();

    try testing.expect(r.isValid());
    const snap = try r.snapshot();
    try testing.expectEqual(@as(u8, SMOOTHING_ONE_EURO), snap.algorithm);
    try testing.expectEqual(ONE_EURO_DEFAULT_MIN_CUTOFF, snap.min_cutoff);
    try testing.expectEqual(ONE_EURO_DEFAULT_BETA, snap.beta);
    try testing.expectEqual(ONE_EURO_DEFAULT_D_CUTOFF, snap.d_cutoff);
    // EMA's alpha is not populated when algorithm is One-Euro.
    try testing.expectEqual(@as(i32, 0), snap.alpha);
}

test "smoothing writer setEma zero-pads after alpha" {
    // Spec: bytes beyond the bytes an algorithm uses are
    // zero-filled. Verify that switching to EMA after writing
    // One-Euro params clears the unused bytes (otherwise stale
    // beta/d_cutoff bytes could be misread by a future
    // algorithm extension or by tooling).
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try tmpSmoothingPath(&tmp, &buf);

    var w = try SmoothingWriter.init(path);
    defer w.deinit();

    w.beginUpdate();
    w.setOneEuro(0x12345678, 0x23456789, 0x34567890);
    w.endUpdate();

    w.beginUpdate();
    w.setEma(EMA_DEFAULT_ALPHA);
    w.endUpdate();

    // Read raw bytes past the alpha to confirm zero-fill.
    const params_off = SMOOTHING_HEADER_SIZE;
    const beta_off = params_off + 4;
    const d_cutoff_off = params_off + 8;
    try testing.expectEqual(@as(u8, 0), w.map[beta_off]);
    try testing.expectEqual(@as(u8, 0), w.map[beta_off + 1]);
    try testing.expectEqual(@as(u8, 0), w.map[beta_off + 2]);
    try testing.expectEqual(@as(u8, 0), w.map[beta_off + 3]);
    try testing.expectEqual(@as(u8, 0), w.map[d_cutoff_off]);
    try testing.expectEqual(@as(u8, 0), w.map[d_cutoff_off + 3]);
}

test "smoothing reader rejects absent file gracefully" {
    const r = SmoothingReader.init("/var/run/sema/input/smoothing_does_not_exist_test");
    defer r.deinit();
    try testing.expect(!r.isValid());
}

test "smoothing reader rejects wrong magic" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try tmpSmoothingPath(&tmp, &buf);

    // Create a file at the right size but with the wrong magic
    // bytes. The reader's init must reject and return a closed
    // reader with map = null.
    var bytes = [_]u8{0} ** SMOOTHING_SIZE;
    // Wrong magic: anything other than INSM (0x494E534D).
    std.mem.writeInt(u32, bytes[0..4], 0xDEADBEEF, .little);
    bytes[SM_OFF_VERSION] = SMOOTHING_VERSION;
    try testCreateWrite(path, &bytes);

    const r = SmoothingReader.init(path);
    defer r.deinit();
    try testing.expect(!r.isValid());
}
