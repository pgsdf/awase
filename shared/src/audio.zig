// audiofs state-region reader/writer API.
//
// Mirrors shared/src/input.zig for the audio state region at
// /var/run/sema/audio/state. The audiofs kernel module is the
// sole writer; userspace consumers (semasound, diagnostic
// tools) are readers. StateWriter here is a userspace helper
// for tests and tools, not the production writer (which is in
// the kernel).
//
// Schema: shared/AUDIO_STATE.md
// Design: audiofs/docs/adr/0012-f1-state-file.md
//
// Physics-only per ADR 0007: the region carries hardware
// capability and current hardware state, not policy.

const std = @import("std");
const posix = std.posix;

// File-local raw-posix helpers. Per ADR shared 0001 and 0002, this module
// memory-maps shared files directly (posix.mmap/munmap survive in 0.16), so it
// adapts to the removed std.fs.*Absolute and posix.* fd wrappers by going
// through posix.system.* rather than routing through compat. These mirror the
// proven helpers in clock.zig and input.zig; the eventual DRY lift into a shared
// posixfile module is the deferred post-migration refactor, not this pass.
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

pub const STATE_PATH = "/var/run/sema/audio/state";
pub const STATE_MAGIC: u32 = 0x54535541; // "AUST"
pub const STATE_VERSION: u8 = 1;

pub const CONTROLLER_SLOTS: usize = 8;
pub const ENDPOINT_SLOTS: usize = 32;

pub const HEADER_SIZE: usize = 64;
pub const CONTROLLER_SLOT_SIZE: usize = 64;
pub const ENDPOINT_SLOT_SIZE: usize = 64;

pub const CONTROLLER_ARRAY_OFFSET: usize = HEADER_SIZE;
pub const ENDPOINT_ARRAY_OFFSET: usize =
    CONTROLLER_ARRAY_OFFSET + CONTROLLER_SLOTS * CONTROLLER_SLOT_SIZE;
pub const STATE_SIZE: usize =
    ENDPOINT_ARRAY_OFFSET + ENDPOINT_SLOTS * ENDPOINT_SLOT_SIZE;

// Header field offsets (shared/AUDIO_STATE.md).
const H_MAGIC: usize = 0;
const H_VERSION: usize = 4;
const H_STATE_VALID: usize = 5;
const H_CONTROLLER_COUNT: usize = 6;
const H_ENDPOINT_COUNT: usize = 7;
const H_SEQLOCK: usize = 8;
const H_INVENTORY_SEQ: usize = 12;
const H_LAST_EVENT_SEQ: usize = 16;
const H_CONTROLLER_SLOT_COUNT: usize = 24;
const H_ENDPOINT_SLOT_COUNT: usize = 25;
const H_CONTROLLER_SLOT_SIZE: usize = 26;
const H_ENDPOINT_SLOT_SIZE: usize = 27;

// Controller slot field offsets (relative to slot start).
const C_CONTROLLER_ID: usize = 0;
const C_SUBTYPE: usize = 4;
const C_PCI_VENDOR: usize = 8;
const C_PCI_DEVICE: usize = 10;
const C_PCI_SUBVENDOR: usize = 12;
const C_PCI_SUBDEVICE: usize = 14;
const C_NUM_ISS: usize = 16;
const C_NUM_OSS: usize = 17;
const C_NUM_BSS: usize = 18;
const C_SUPPORT_64BIT: usize = 19;
const C_NAME: usize = 24;
const C_NAME_LEN: usize = 40;

// Endpoint slot field offsets (relative to slot start).
const E_ENDPOINT_ID: usize = 0;
const E_CONTROLLER_IDX: usize = 4;
const E_CODEC_ADDR: usize = 5;
const E_KIND: usize = 6;
const E_DIRECTION: usize = 7;
const E_PIN_NID: usize = 8;
const E_CONVERTER_NID: usize = 10;
const E_ELECTRICALLY_READY: usize = 12;
const E_RUNTIME_ACTIVE: usize = 13;
const E_CURRENT_FORMAT: usize = 14;
const E_RATE_MASK: usize = 16;
const E_BIT_DEPTH_MASK: usize = 20;
const E_CHANNEL_MASK: usize = 24;
const E_NAME: usize = 32;
const E_NAME_LEN: usize = 32;

// Controller subtype.
pub const SUBTYPE_UNUSED: u8 = 0;
pub const SUBTYPE_PCI_HDA: u8 = 1;
pub const SUBTYPE_USB_AUDIO: u8 = 2;

// Endpoint direction.
pub const DIR_UNUSED: u8 = 0;
pub const DIR_OUTPUT: u8 = 1;
pub const DIR_INPUT: u8 = 2;
pub const DIR_LOOPBACK: u8 = 3;

// Endpoint kind.
pub const KIND_UNUSED: u8 = 0;
pub const KIND_SPEAKER: u8 = 1;
pub const KIND_HEADPHONE: u8 = 2;
pub const KIND_LINE_OUT: u8 = 3;
pub const KIND_MIC: u8 = 4;
pub const KIND_LINE_IN: u8 = 5;
pub const KIND_HDMI: u8 = 6;
pub const KIND_DISPLAYPORT: u8 = 7;
pub const KIND_SPDIF: u8 = 8;

pub fn kindName(kind: u8) []const u8 {
    return switch (kind) {
        KIND_SPEAKER => "speaker",
        KIND_HEADPHONE => "headphone",
        KIND_LINE_OUT => "line-out",
        KIND_MIC => "mic",
        KIND_LINE_IN => "line-in",
        KIND_HDMI => "hdmi",
        KIND_DISPLAYPORT => "displayport",
        KIND_SPDIF => "spdif",
        else => "unused",
    };
}

pub fn directionName(dir: u8) []const u8 {
    return switch (dir) {
        DIR_OUTPUT => "output",
        DIR_INPUT => "input",
        DIR_LOOPBACK => "loopback",
        else => "unused",
    };
}

pub const Controller = struct {
    controller_id: u32,
    subtype: u8,
    pci_vendor: u16,
    pci_device: u16,
    pci_subvendor: u16,
    pci_subdevice: u16,
    num_iss: u8,
    num_oss: u8,
    num_bss: u8,
    support_64bit: u8,
    name: [C_NAME_LEN]u8,

    pub fn nameSlice(self: *const Controller) []const u8 {
        return sliceCStr(self.name[0..]);
    }
};

pub const Endpoint = struct {
    endpoint_id: u32,
    controller_idx: u8,
    codec_addr: u8,
    kind: u8,
    direction: u8,
    pin_nid: u16,
    converter_nid: u16,
    electrically_ready: u8,
    runtime_active: u8,
    current_format: u16,
    rate_mask: u32,
    bit_depth_mask: u32,
    channel_mask: u8,
    name: [E_NAME_LEN]u8,

    pub fn nameSlice(self: *const Endpoint) []const u8 {
        return sliceCStr(self.name[0..]);
    }
};

pub const Snapshot = struct {
    controller_count: u8,
    endpoint_count: u8,
    inventory_seq: u32,
    last_event_seq: u64,
    controllers: [CONTROLLER_SLOTS]Controller,
    endpoints: [ENDPOINT_SLOTS]Endpoint,

    pub fn controllerSlice(self: *const Snapshot) []const Controller {
        return self.controllers[0..self.controller_count];
    }

    pub fn endpointSlice(self: *const Snapshot) []const Endpoint {
        return self.endpoints[0..self.endpoint_count];
    }

    pub fn findEndpointById(self: *const Snapshot, id: u32) ?*const Endpoint {
        var i: usize = 0;
        while (i < self.endpoint_count) : (i += 1) {
            if (self.endpoints[i].endpoint_id == id)
                return &self.endpoints[i];
        }
        return null;
    }
};

fn sliceCStr(buf: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, buf, 0) orelse buf.len;
    return buf[0..end];
}

fn atomicU32PtrConst(map: []const u8, off: usize) *const u32 {
    return @alignCast(std.mem.bytesAsValue(u32, map[off..][0..4]));
}

pub const StateReader = struct {
    map: ?[]const u8,
    fd: posix.fd_t,

    pub fn init(path: []const u8) StateReader {
        const raw_fd = openReadOnly(path) catch {
            return .{ .map = null, .fd = -1 };
        };

        // Defensive: confirm the file is at least STATE_SIZE
        // bytes before mmap-ing. An mmap larger than the file
        // succeeds but reads past the end fault. This matches
        // the StateReader.init rationale in input.zig: a reader
        // opening during the kernel's create/truncate/grow
        // window, or after a partial write, should be treated
        // identically to "file absent".
        const end_pos = fileSize(raw_fd) catch {
            posix.system.close(raw_fd);
            return .{ .map = null, .fd = -1 };
        };
        if (end_pos < @as(u64, STATE_SIZE)) {
            posix.system.close(raw_fd);
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
            posix.system.close(raw_fd);
            return .{ .map = null, .fd = -1 };
        };

        const map: []const u8 = map_raw[0..STATE_SIZE];
        const magic = std.mem.readInt(u32, map[H_MAGIC..][0..4], .little);
        if (magic != STATE_MAGIC or map[H_VERSION] != STATE_VERSION) {
            posix.munmap(@alignCast(map_raw));
            posix.system.close(raw_fd);
            return .{ .map = null, .fd = -1 };
        }

        return .{ .map = map, .fd = raw_fd };
    }

    pub fn deinit(self: StateReader) void {
        if (self.map) |m| posix.munmap(@alignCast(@constCast(m)));
        if (self.fd >= 0) posix.system.close(self.fd);
    }

    pub fn isValid(self: StateReader) bool {
        const m = self.map orelse return false;
        return @atomicLoad(u8, &m[H_STATE_VALID], .seq_cst) != 0;
    }

    pub fn inventorySeq(self: StateReader) u32 {
        const m = self.map orelse return 0;
        return std.mem.readInt(u32, m[H_INVENTORY_SEQ..][0..4], .little);
    }

    fn readController(m: []const u8, slot: usize) Controller {
        const base = CONTROLLER_ARRAY_OFFSET + slot * CONTROLLER_SLOT_SIZE;
        var c: Controller = undefined;
        c.controller_id = std.mem.readInt(u32, m[base + C_CONTROLLER_ID ..][0..4], .little);
        c.subtype = m[base + C_SUBTYPE];
        c.pci_vendor = std.mem.readInt(u16, m[base + C_PCI_VENDOR ..][0..2], .little);
        c.pci_device = std.mem.readInt(u16, m[base + C_PCI_DEVICE ..][0..2], .little);
        c.pci_subvendor = std.mem.readInt(u16, m[base + C_PCI_SUBVENDOR ..][0..2], .little);
        c.pci_subdevice = std.mem.readInt(u16, m[base + C_PCI_SUBDEVICE ..][0..2], .little);
        c.num_iss = m[base + C_NUM_ISS];
        c.num_oss = m[base + C_NUM_OSS];
        c.num_bss = m[base + C_NUM_BSS];
        c.support_64bit = m[base + C_SUPPORT_64BIT];
        @memcpy(c.name[0..], m[base + C_NAME ..][0..C_NAME_LEN]);
        return c;
    }

    fn readEndpoint(m: []const u8, slot: usize) Endpoint {
        const base = ENDPOINT_ARRAY_OFFSET + slot * ENDPOINT_SLOT_SIZE;
        var e: Endpoint = undefined;
        e.endpoint_id = std.mem.readInt(u32, m[base + E_ENDPOINT_ID ..][0..4], .little);
        e.controller_idx = m[base + E_CONTROLLER_IDX];
        e.codec_addr = m[base + E_CODEC_ADDR];
        e.kind = m[base + E_KIND];
        e.direction = m[base + E_DIRECTION];
        e.pin_nid = std.mem.readInt(u16, m[base + E_PIN_NID ..][0..2], .little);
        e.converter_nid = std.mem.readInt(u16, m[base + E_CONVERTER_NID ..][0..2], .little);
        e.electrically_ready = m[base + E_ELECTRICALLY_READY];
        e.runtime_active = m[base + E_RUNTIME_ACTIVE];
        e.current_format = std.mem.readInt(u16, m[base + E_CURRENT_FORMAT ..][0..2], .little);
        e.rate_mask = std.mem.readInt(u32, m[base + E_RATE_MASK ..][0..4], .little);
        e.bit_depth_mask = std.mem.readInt(u32, m[base + E_BIT_DEPTH_MASK ..][0..4], .little);
        e.channel_mask = m[base + E_CHANNEL_MASK];
        @memcpy(e.name[0..], m[base + E_NAME ..][0..E_NAME_LEN]);
        return e;
    }

    /// Read a consistent snapshot using the seqlock pattern
    /// from shared/AUDIO_STATE.md "Concurrency model".
    ///
    /// Returns error.NotOpen if the reader was never
    /// initialised; error.SeqlockContended after MAX_ATTEMPTS
    /// retries; null if the region is not currently valid.
    pub fn snapshot(self: StateReader) !?Snapshot {
        const m = self.map orelse return error.NotOpen;
        if (@atomicLoad(u8, &m[H_STATE_VALID], .seq_cst) == 0) return null;

        const seqlock_ptr = atomicU32PtrConst(m, H_SEQLOCK);

        var attempt: usize = 0;
        const MAX_ATTEMPTS: usize = 1024;
        while (attempt < MAX_ATTEMPTS) : (attempt += 1) {
            const v1 = @atomicLoad(u32, seqlock_ptr, .seq_cst);
            if (v1 & 1 != 0) {
                std.atomic.spinLoopHint();
                continue;
            }

            var snap: Snapshot = undefined;
            snap.controller_count = m[H_CONTROLLER_COUNT];
            snap.endpoint_count = m[H_ENDPOINT_COUNT];
            snap.inventory_seq = std.mem.readInt(u32, m[H_INVENTORY_SEQ..][0..4], .little);
            snap.last_event_seq = std.mem.readInt(u64, m[H_LAST_EVENT_SEQ..][0..8], .little);

            // Clamp counts defensively against the slot capacity.
            if (snap.controller_count > CONTROLLER_SLOTS)
                snap.controller_count = CONTROLLER_SLOTS;
            if (snap.endpoint_count > ENDPOINT_SLOTS)
                snap.endpoint_count = ENDPOINT_SLOTS;

            var i: usize = 0;
            while (i < CONTROLLER_SLOTS) : (i += 1)
                snap.controllers[i] = readController(m, i);
            i = 0;
            while (i < ENDPOINT_SLOTS) : (i += 1)
                snap.endpoints[i] = readEndpoint(m, i);

            const v2 = @atomicLoad(u32, seqlock_ptr, .seq_cst);
            if (v2 == v1) return snap;
        }
        return error.SeqlockContended;
    }
};

// ============================================================================
// Events ring (F.2)
//
// Reader for /var/run/sema/audio/events. audiofs is the sole
// writer. Mirrors shared/src/input.zig's EventRingReader.
// Schema: shared/AUDIO_EVENTS.md
// ============================================================================

pub const EVENTS_PATH = "/var/run/sema/audio/events";
pub const EVENTS_MAGIC: u32 = 0x41554556; // "AUEV"
pub const EVENTS_VERSION: u8 = 1;

pub const EVENTS_SLOT_COUNT: u64 = 256;
pub const EVENTS_SLOT_SIZE: usize = 64;
pub const EVENTS_HEADER_SIZE: usize = 64;
pub const EVENTS_SIZE: usize =
    EVENTS_HEADER_SIZE + @as(usize, EVENTS_SLOT_COUNT) * EVENTS_SLOT_SIZE;

// Header field offsets (shared/AUDIO_EVENTS.md).
const EV_OFF_MAGIC: usize = 0;
const EV_OFF_VERSION: usize = 4;
const EV_OFF_RING_VALID: usize = 5;
const EV_OFF_EVENT_SIZE: usize = 6;
const EV_OFF_SLOT_COUNT: usize = 8;
const EV_OFF_WRITER_SEQ: usize = 16;
const EV_OFF_EARLIEST_SEQ: usize = 24;

// Event slot field offsets (relative to slot start).
const EV_SLOT_OFF_SEQ: usize = 0;
const EV_SLOT_OFF_TS_ORDERING: usize = 8;
const EV_SLOT_OFF_TS_SYNC: usize = 16;
const EV_SLOT_OFF_ENDPOINT_SLOT: usize = 24;
const EV_SLOT_OFF_SOURCE_ROLE: usize = 26;
const EV_SLOT_OFF_EVENT_TYPE: usize = 27;
const EV_SLOT_OFF_FLAGS: usize = 28;
const EV_SLOT_OFF_PAYLOAD: usize = 32;

// source_role values.
pub const EVROLE_STREAM: u8 = 1;
pub const EVROLE_ENDPOINT: u8 = 2;

// event_type under role STREAM.
pub const EVSTREAM_BEGIN: u8 = 1;
pub const EVSTREAM_END: u8 = 2;
pub const EVSTREAM_XRUN: u8 = 3;
pub const EVSTREAM_FORMAT_CHANGE: u8 = 4;

// event_type under role ENDPOINT.
pub const EVENDPOINT_ATTACH: u8 = 1;
pub const EVENDPOINT_DETACH: u8 = 2;
pub const EVENDPOINT_INVENTORY_FULL: u8 = 3;

pub const EVENTS_NO_ENDPOINT: u16 = 0xffff;

fn atomicU64PtrConst(map: []const u8, off: usize) *const u64 {
    return @alignCast(std.mem.bytesAsValue(u64, map[off..][0..8]));
}

pub const Event = struct {
    seq: u64,
    ts_ordering: u64,
    ts_sync: u64,
    endpoint_slot: u16,
    source_role: u8,
    event_type: u8,
    flags: u32,
    payload: [32]u8,

    /// Decode the endpoint_attach payload (role=endpoint, type=attach).
    pub fn endpointAttach(self: *const Event) struct {
        endpoint_id: u32,
        kind: u8,
        direction: u8,
        controller_idx: u8,
    } {
        return .{
            .endpoint_id = std.mem.readInt(u32, self.payload[0..4], .little),
            .kind = self.payload[4],
            .direction = self.payload[5],
            .controller_idx = self.payload[6],
        };
    }

    /// Decode the xrun payload (role=stream, type=xrun).
    pub fn xrun(self: *const Event) struct {
        stream_id: u32,
        xrun_kind: u8,
        gap_sample_pos: u64,
        gap_frames: u32,
    } {
        return .{
            .stream_id = std.mem.readInt(u32, self.payload[0..4], .little),
            .xrun_kind = self.payload[4],
            .gap_sample_pos = std.mem.readInt(u64, self.payload[8..16], .little),
            .gap_frames = std.mem.readInt(u32, self.payload[16..20], .little),
        };
    }

    /// Decode the stream_begin payload (role=stream, type=stream_begin).
    /// Payload layout per shared/AUDIO_EVENTS.md: stream_id(u32 0..4),
    /// format(u16 4..6), channels(u8 6), _pad(u8 7), rate_hz(u32 8..12).
    pub fn streamBegin(self: *const Event) struct {
        stream_id: u32,
        format: u16,
        channels: u8,
        rate_hz: u32,
    } {
        return .{
            .stream_id = std.mem.readInt(u32, self.payload[0..4], .little),
            .format = std.mem.readInt(u16, self.payload[4..6], .little),
            .channels = self.payload[6],
            .rate_hz = std.mem.readInt(u32, self.payload[8..12], .little),
        };
    }

    /// Decode the stream_end payload (role=stream, type=stream_end).
    /// Payload layout per shared/AUDIO_EVENTS.md: stream_id(u32 0..4),
    /// _pad(u32 4..8), frames_total(u64 8..16).
    pub fn streamEnd(self: *const Event) struct {
        stream_id: u32,
        frames_total: u64,
    } {
        return .{
            .stream_id = std.mem.readInt(u32, self.payload[0..4], .little),
            .frames_total = std.mem.readInt(u64, self.payload[8..16], .little),
        };
    }
};

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

        // Defensive size check before mmap (see StateReader.init).
        const end_pos = fileSize(raw_fd) catch {
            posix.system.close(raw_fd);
            return .{ .map = null, .fd = -1, .last_consumed = 0 };
        };
        if (end_pos < @as(u64, EVENTS_SIZE)) {
            posix.system.close(raw_fd);
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
            posix.system.close(raw_fd);
            return .{ .map = null, .fd = -1, .last_consumed = 0 };
        };

        const map: []const u8 = map_raw[0..EVENTS_SIZE];
        const magic = std.mem.readInt(u32, map[EV_OFF_MAGIC..][0..4], .little);
        if (magic != EVENTS_MAGIC or map[EV_OFF_VERSION] != EVENTS_VERSION) {
            posix.munmap(@alignCast(map_raw));
            posix.system.close(raw_fd);
            return .{ .map = null, .fd = -1, .last_consumed = 0 };
        }

        return .{ .map = map, .fd = raw_fd, .last_consumed = 0 };
    }

    pub fn deinit(self: EventRingReader) void {
        if (self.map) |m| posix.munmap(@alignCast(@constCast(m)));
        if (self.fd >= 0) posix.system.close(self.fd);
    }

    pub fn isValid(self: EventRingReader) bool {
        const m = self.map orelse return false;
        return @atomicLoad(u8, &m[EV_OFF_RING_VALID], .seq_cst) != 0;
    }

    pub fn writerSeq(self: EventRingReader) u64 {
        const m = self.map orelse return 0;
        return @atomicLoad(u64, atomicU64PtrConst(m, EV_OFF_WRITER_SEQ), .seq_cst);
    }

    pub fn earliestSeq(self: EventRingReader) u64 {
        const m = self.map orelse return 0;
        return @atomicLoad(u64, atomicU64PtrConst(m, EV_OFF_EARLIEST_SEQ), .seq_cst);
    }

    /// Position the cursor at the current writer_seq, so drain()
    /// returns only events published after this call. Mirrors the
    /// inputfs consumer pattern that avoids replaying the whole
    /// ring at attach time.
    pub fn seekToEnd(self: *EventRingReader) void {
        self.last_consumed = self.writerSeq();
    }

    /// Drain newly published events into `out`. Returns the count
    /// consumed and whether overrun was detected. On overrun,
    /// last_consumed is repositioned to earliestSeq() - 1; the
    /// caller should resynchronise from the state region per
    /// AUDIO_EVENTS.md "Failure modes".
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
            const slot_base = EVENTS_HEADER_SIZE + @as(usize, slot_idx) * EVENTS_SLOT_SIZE;
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
            ev.endpoint_slot = std.mem.readInt(u16, m[slot_base + EV_SLOT_OFF_ENDPOINT_SLOT ..][0..2], .little);
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

// --- Tests ---

test "constants match shared/AUDIO_STATE.md" {
    try std.testing.expectEqual(@as(usize, 64), HEADER_SIZE);
    try std.testing.expectEqual(@as(usize, 64), CONTROLLER_SLOT_SIZE);
    try std.testing.expectEqual(@as(usize, 64), ENDPOINT_SLOT_SIZE);
    try std.testing.expectEqual(@as(usize, 576), ENDPOINT_ARRAY_OFFSET);
    try std.testing.expectEqual(@as(usize, 2624), STATE_SIZE);
    try std.testing.expectEqual(@as(u32, 0x54535541), STATE_MAGIC);
}

test "snapshot parses a hand-built region" {
    var buf align(8) = [_]u8{0} ** STATE_SIZE;

    // Header
    std.mem.writeInt(u32, buf[H_MAGIC..][0..4], STATE_MAGIC, .little);
    buf[H_VERSION] = STATE_VERSION;
    buf[H_STATE_VALID] = 1;
    buf[H_CONTROLLER_COUNT] = 1;
    buf[H_ENDPOINT_COUNT] = 2;
    std.mem.writeInt(u32, buf[H_SEQLOCK..][0..4], 4, .little); // even
    std.mem.writeInt(u32, buf[H_INVENTORY_SEQ..][0..4], 2, .little);

    // Controller slot 0
    const cbase = CONTROLLER_ARRAY_OFFSET;
    std.mem.writeInt(u32, buf[cbase + C_CONTROLLER_ID ..][0..4], 1, .little);
    buf[cbase + C_SUBTYPE] = SUBTYPE_PCI_HDA;
    std.mem.writeInt(u16, buf[cbase + C_PCI_VENDOR ..][0..2], 0x8086, .little);
    std.mem.writeInt(u16, buf[cbase + C_PCI_DEVICE ..][0..2], 0x9d71, .little);
    buf[cbase + C_NUM_OSS] = 4;

    // Endpoint slot 0: speaker, active
    const e0 = ENDPOINT_ARRAY_OFFSET;
    std.mem.writeInt(u32, buf[e0 + E_ENDPOINT_ID ..][0..4], 1, .little);
    buf[e0 + E_KIND] = KIND_SPEAKER;
    buf[e0 + E_DIRECTION] = DIR_OUTPUT;
    buf[e0 + E_RUNTIME_ACTIVE] = 1;
    std.mem.writeInt(u16, buf[e0 + E_CURRENT_FORMAT ..][0..2], 0x0011, .little);
    buf[e0 + E_CHANNEL_MASK] = 0x02;

    // Endpoint slot 1: headphone, idle
    const e1 = ENDPOINT_ARRAY_OFFSET + ENDPOINT_SLOT_SIZE;
    std.mem.writeInt(u32, buf[e1 + E_ENDPOINT_ID ..][0..4], 2, .little);
    buf[e1 + E_KIND] = KIND_HEADPHONE;
    buf[e1 + E_DIRECTION] = DIR_OUTPUT;

    const m: []const u8 = buf[0..];
    const reader = StateReader{ .map = m, .fd = -1 };
    const maybe = try reader.snapshot();
    try std.testing.expect(maybe != null);
    const snap = maybe.?;

    try std.testing.expectEqual(@as(u8, 1), snap.controller_count);
    try std.testing.expectEqual(@as(u8, 2), snap.endpoint_count);
    try std.testing.expectEqual(@as(u32, 2), snap.inventory_seq);

    const ctrls = snap.controllerSlice();
    try std.testing.expectEqual(@as(usize, 1), ctrls.len);
    try std.testing.expectEqual(@as(u16, 0x8086), ctrls[0].pci_vendor);
    try std.testing.expectEqual(@as(u8, 4), ctrls[0].num_oss);

    const eps = snap.endpointSlice();
    try std.testing.expectEqual(@as(usize, 2), eps.len);
    try std.testing.expectEqual(KIND_SPEAKER, eps[0].kind);
    try std.testing.expectEqual(@as(u8, 1), eps[0].runtime_active);
    try std.testing.expectEqual(KIND_HEADPHONE, eps[1].kind);
    try std.testing.expectEqual(@as(u8, 0), eps[1].runtime_active);

    const found = snap.findEndpointById(2);
    try std.testing.expect(found != null);
    try std.testing.expectEqual(KIND_HEADPHONE, found.?.kind);

    try std.testing.expect(snap.findEndpointById(99) == null);
}

test "snapshot returns null when state_valid is 0" {
    var buf align(8) = [_]u8{0} ** STATE_SIZE;
    std.mem.writeInt(u32, buf[H_MAGIC..][0..4], STATE_MAGIC, .little);
    buf[H_VERSION] = STATE_VERSION;
    buf[H_STATE_VALID] = 0;

    const reader = StateReader{ .map = buf[0..], .fd = -1 };
    const maybe = try reader.snapshot();
    try std.testing.expect(maybe == null);
}

test "snapshot retries on odd seqlock then fails contended" {
    var buf align(8) = [_]u8{0} ** STATE_SIZE;
    std.mem.writeInt(u32, buf[H_MAGIC..][0..4], STATE_MAGIC, .little);
    buf[H_VERSION] = STATE_VERSION;
    buf[H_STATE_VALID] = 1;
    std.mem.writeInt(u32, buf[H_SEQLOCK..][0..4], 1, .little); // odd: write in progress

    const reader = StateReader{ .map = buf[0..], .fd = -1 };
    try std.testing.expectError(error.SeqlockContended, reader.snapshot());
}

test "events constants match shared/AUDIO_EVENTS.md" {
    try std.testing.expectEqual(@as(usize, 64), EVENTS_HEADER_SIZE);
    try std.testing.expectEqual(@as(usize, 64), EVENTS_SLOT_SIZE);
    try std.testing.expectEqual(@as(u64, 256), EVENTS_SLOT_COUNT);
    try std.testing.expectEqual(@as(usize, 16448), EVENTS_SIZE);
    try std.testing.expectEqual(@as(u32, 0x41554556), EVENTS_MAGIC);
    // slot_count is a power of two
    try std.testing.expect((EVENTS_SLOT_COUNT & (EVENTS_SLOT_COUNT - 1)) == 0);
}

// Helper: write one event slot into a ring buffer, seq last.
fn writeEventSlot(
    buf: []u8,
    seq: u64,
    role: u8,
    etype: u8,
    endpoint_slot: u16,
    payload: []const u8,
) void {
    const idx = seq & (EVENTS_SLOT_COUNT - 1);
    const base = EVENTS_HEADER_SIZE + @as(usize, idx) * EVENTS_SLOT_SIZE;
    std.mem.writeInt(u64, buf[base + EV_SLOT_OFF_TS_ORDERING ..][0..8], 12345, .little);
    std.mem.writeInt(u64, buf[base + EV_SLOT_OFF_TS_SYNC ..][0..8], 0, .little);
    std.mem.writeInt(u16, buf[base + EV_SLOT_OFF_ENDPOINT_SLOT ..][0..2], endpoint_slot, .little);
    buf[base + EV_SLOT_OFF_SOURCE_ROLE] = role;
    buf[base + EV_SLOT_OFF_EVENT_TYPE] = etype;
    std.mem.writeInt(u32, buf[base + EV_SLOT_OFF_FLAGS ..][0..4], 0, .little);
    const plen = if (payload.len > 32) 32 else payload.len;
    @memcpy(buf[base + EV_SLOT_OFF_PAYLOAD ..][0..plen], payload[0..plen]);
    // seq published last
    std.mem.writeInt(u64, buf[base + EV_SLOT_OFF_SEQ ..][0..8], seq, .little);
}

test "events ring drains endpoint_attach events" {
    var buf align(8) = [_]u8{0} ** EVENTS_SIZE;

    // Header
    std.mem.writeInt(u32, buf[EV_OFF_MAGIC..][0..4], EVENTS_MAGIC, .little);
    buf[EV_OFF_VERSION] = EVENTS_VERSION;
    buf[EV_OFF_RING_VALID] = 1;
    std.mem.writeInt(u16, buf[EV_OFF_EVENT_SIZE..][0..2], EVENTS_SLOT_SIZE, .little);
    std.mem.writeInt(u32, buf[EV_OFF_SLOT_COUNT..][0..4], @intCast(EVENTS_SLOT_COUNT), .little);
    std.mem.writeInt(u64, buf[EV_OFF_EARLIEST_SEQ..][0..8], 1, .little);

    // Two endpoint_attach events: ids 8 (speaker) and 2 (headphone).
    var p0 = [_]u8{0} ** 32;
    std.mem.writeInt(u32, p0[0..4], 8, .little);
    p0[4] = KIND_SPEAKER;
    p0[5] = DIR_OUTPUT;
    p0[6] = 0; // controller_idx
    writeEventSlot(buf[0..], 1, EVROLE_ENDPOINT, EVENDPOINT_ATTACH, 2, p0[0..]);

    var p1 = [_]u8{0} ** 32;
    std.mem.writeInt(u32, p1[0..4], 2, .little);
    p1[4] = KIND_HEADPHONE;
    p1[5] = DIR_OUTPUT;
    p1[6] = 0;
    writeEventSlot(buf[0..], 2, EVROLE_ENDPOINT, EVENDPOINT_ATTACH, 1, p1[0..]);

    // Publish writer_seq last.
    std.mem.writeInt(u64, buf[EV_OFF_WRITER_SEQ..][0..8], 2, .little);

    var reader = EventRingReader{ .map = buf[0..], .fd = -1, .last_consumed = 0 };
    try std.testing.expect(reader.isValid());
    try std.testing.expectEqual(@as(u64, 2), reader.writerSeq());

    var out: [16]Event = undefined;
    const res = try reader.drain(out[0..]);
    try std.testing.expectEqual(@as(usize, 2), res.events_consumed);
    try std.testing.expect(!res.overrun);

    try std.testing.expectEqual(EVROLE_ENDPOINT, out[0].source_role);
    try std.testing.expectEqual(EVENDPOINT_ATTACH, out[0].event_type);
    const a0 = out[0].endpointAttach();
    try std.testing.expectEqual(@as(u32, 8), a0.endpoint_id);
    try std.testing.expectEqual(KIND_SPEAKER, a0.kind);
    try std.testing.expectEqual(DIR_OUTPUT, a0.direction);

    const a1 = out[1].endpointAttach();
    try std.testing.expectEqual(@as(u32, 2), a1.endpoint_id);
    try std.testing.expectEqual(KIND_HEADPHONE, a1.kind);

    // A second drain with no new events returns nothing.
    const res2 = try reader.drain(out[0..]);
    try std.testing.expectEqual(@as(usize, 0), res2.events_consumed);
}

test "events ring decodes xrun payload with gap position" {
    var buf align(8) = [_]u8{0} ** EVENTS_SIZE;
    std.mem.writeInt(u32, buf[EV_OFF_MAGIC..][0..4], EVENTS_MAGIC, .little);
    buf[EV_OFF_VERSION] = EVENTS_VERSION;
    buf[EV_OFF_RING_VALID] = 1;
    std.mem.writeInt(u64, buf[EV_OFF_EARLIEST_SEQ..][0..8], 1, .little);

    var p = [_]u8{0} ** 32;
    std.mem.writeInt(u32, p[0..4], 1, .little); // stream_id
    p[4] = 0; // underrun
    std.mem.writeInt(u64, p[8..16], 48000, .little); // gap_sample_pos
    std.mem.writeInt(u32, p[16..20], 256, .little); // gap_frames
    writeEventSlot(buf[0..], 1, EVROLE_STREAM, EVSTREAM_XRUN, 0, p[0..]);
    std.mem.writeInt(u64, buf[EV_OFF_WRITER_SEQ..][0..8], 1, .little);

    var reader = EventRingReader{ .map = buf[0..], .fd = -1, .last_consumed = 0 };
    var out: [4]Event = undefined;
    const res = try reader.drain(out[0..]);
    try std.testing.expectEqual(@as(usize, 1), res.events_consumed);

    const x = out[0].xrun();
    try std.testing.expectEqual(@as(u32, 1), x.stream_id);
    try std.testing.expectEqual(@as(u8, 0), x.xrun_kind);
    try std.testing.expectEqual(@as(u64, 48000), x.gap_sample_pos);
    try std.testing.expectEqual(@as(u32, 256), x.gap_frames);
}

test "events ring detects overrun" {
    var buf align(8) = [_]u8{0} ** EVENTS_SIZE;
    std.mem.writeInt(u32, buf[EV_OFF_MAGIC..][0..4], EVENTS_MAGIC, .little);
    buf[EV_OFF_VERSION] = EVENTS_VERSION;
    buf[EV_OFF_RING_VALID] = 1;
    // Writer is far ahead; earliest has advanced past our cursor.
    std.mem.writeInt(u64, buf[EV_OFF_WRITER_SEQ..][0..8], 500, .little);
    std.mem.writeInt(u64, buf[EV_OFF_EARLIEST_SEQ..][0..8], 245, .little);

    var reader = EventRingReader{ .map = buf[0..], .fd = -1, .last_consumed = 10 };
    var out: [8]Event = undefined;
    const res = try reader.drain(out[0..]);
    try std.testing.expect(res.overrun);
    // cursor repositioned to earliest - 1
    try std.testing.expectEqual(@as(u64, 244), reader.last_consumed);
}

test "events ring decodes stream_begin payload" {
    var buf align(8) = [_]u8{0} ** EVENTS_SIZE;
    std.mem.writeInt(u32, buf[EV_OFF_MAGIC..][0..4], EVENTS_MAGIC, .little);
    buf[EV_OFF_VERSION] = EVENTS_VERSION;
    buf[EV_OFF_RING_VALID] = 1;
    std.mem.writeInt(u64, buf[EV_OFF_EARLIEST_SEQ..][0..8], 1, .little);

    var p = [_]u8{0} ** 32;
    std.mem.writeInt(u32, p[0..4], 1, .little); // stream_id
    std.mem.writeInt(u16, p[4..6], 0x0011, .little); // format
    p[6] = 2; // channels
    // p[7] = 0 (padding)
    std.mem.writeInt(u32, p[8..12], 48000, .little); // rate_hz
    writeEventSlot(buf[0..], 1, EVROLE_STREAM, EVSTREAM_BEGIN, 2, p[0..]);
    std.mem.writeInt(u64, buf[EV_OFF_WRITER_SEQ..][0..8], 1, .little);

    var reader = EventRingReader{ .map = buf[0..], .fd = -1, .last_consumed = 0 };
    var out: [4]Event = undefined;
    const res = try reader.drain(out[0..]);
    try std.testing.expectEqual(@as(usize, 1), res.events_consumed);

    try std.testing.expectEqual(EVROLE_STREAM, out[0].source_role);
    try std.testing.expectEqual(EVSTREAM_BEGIN, out[0].event_type);

    const b = out[0].streamBegin();
    try std.testing.expectEqual(@as(u32, 1), b.stream_id);
    try std.testing.expectEqual(@as(u16, 0x0011), b.format);
    try std.testing.expectEqual(@as(u8, 2), b.channels);
    try std.testing.expectEqual(@as(u32, 48000), b.rate_hz);
}

test "events ring decodes stream_end payload" {
    var buf align(8) = [_]u8{0} ** EVENTS_SIZE;
    std.mem.writeInt(u32, buf[EV_OFF_MAGIC..][0..4], EVENTS_MAGIC, .little);
    buf[EV_OFF_VERSION] = EVENTS_VERSION;
    buf[EV_OFF_RING_VALID] = 1;
    std.mem.writeInt(u64, buf[EV_OFF_EARLIEST_SEQ..][0..8], 1, .little);

    var p = [_]u8{0} ** 32;
    std.mem.writeInt(u32, p[0..4], 1, .little); // stream_id
    // p[4..8] = 0 (padding)
    std.mem.writeInt(u64, p[8..16], 480000, .little); // frames_total = 10 seconds at 48000
    writeEventSlot(buf[0..], 1, EVROLE_STREAM, EVSTREAM_END, 2, p[0..]);
    std.mem.writeInt(u64, buf[EV_OFF_WRITER_SEQ..][0..8], 1, .little);

    var reader = EventRingReader{ .map = buf[0..], .fd = -1, .last_consumed = 0 };
    var out: [4]Event = undefined;
    const res = try reader.drain(out[0..]);
    try std.testing.expectEqual(@as(usize, 1), res.events_consumed);

    try std.testing.expectEqual(EVROLE_STREAM, out[0].source_role);
    try std.testing.expectEqual(EVSTREAM_END, out[0].event_type);

    const e = out[0].streamEnd();
    try std.testing.expectEqual(@as(u32, 1), e.stream_id);
    try std.testing.expectEqual(@as(u64, 480000), e.frames_total);
}
