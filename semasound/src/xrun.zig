// F.5.a xrun event consumer (ADR 0021 Decision 5).
//
// Minimal record-and-continue xrun handling. A thread blocks on
// poll(/dev/audiofs_notify), and on each wake reads the F.2 events region
// (/var/run/sema/audio/events) and counts any new STREAM/XRUN slots since
// the last seq it saw. The gap has already happened in hardware (ADR 0007
// stress case 1; audiofs does not smooth it); semasound's policy here is to
// observe and continue, not to recover. The count is exposed for the bench
// (criterion 7) and for later observability.
//
// Byte layout mirrors audiofs_events.h exactly (the kernel writer): a
// 64-byte header then 256 slots of 64 bytes. Field offsets are pinned by
// the extern structs and asserted by size at startup.

const std = @import("std");
const posix = std.posix;
const protocol = @import("protocol.zig");

const SLOT_COUNT: usize = 256;
const SLOT_SIZE: usize = 64;
const HEADER_SIZE: usize = 64;
const REGION_SIZE: usize = HEADER_SIZE + SLOT_COUNT * SLOT_SIZE;

const EVENTS_MAGIC: u32 = 0x41554556; // 'AUEV'
const ROLE_STREAM: u8 = 1;
const EVTYPE_XRUN: u8 = 3;

const Header = extern struct {
    magic: u32,
    version: u8,
    ring_valid: u8,
    event_size: u16,
    slot_count: u32,
    _pad0: u32,
    writer_seq: u64,
    earliest_seq: u64,
    _pad1: [32]u8,
};

const Slot = extern struct {
    seq: u64,
    ts_ordering: u64,
    ts_sync: u64,
    endpoint_slot: u16,
    source_role: u8,
    event_type: u8,
    flags: u32,
    payload: [32]u8,
};

comptime {
    std.debug.assert(@sizeOf(Header) == HEADER_SIZE);
    std.debug.assert(@sizeOf(Slot) == SLOT_SIZE);
}

pub const Ctx = struct {
    stop: *std.atomic.Value(bool),
    xrun_count: *std.atomic.Value(u64),
};

/// Poll the notify cdev and count new STREAM/XRUN events. Runs until stop.
pub fn run(ctx: Ctx) void {
    const nfd = posix.open(protocol.NOTIFY_PATH, .{ .ACCMODE = .RDONLY }, 0) catch |e| {
        std.debug.print("semasound: xrun consumer: cannot open {s}: {any}\n", .{ protocol.NOTIFY_PATH, e });
        return;
    };
    defer posix.close(nfd);

    var region: [REGION_SIZE]u8 = undefined;

    // Establish the baseline: the writer_seq at startup. Only events newer
    // than this are counted, so pre-existing history is not replayed.
    var last_seq: u64 = readWriterSeq(&region) orelse 0;

    var fds = [_]posix.pollfd{.{
        .fd = nfd,
        .events = posix.POLL.IN,
        .revents = 0,
    }};

    while (!ctx.stop.load(.acquire)) {
        // The notify cdev is edge-triggered and has NO read syscall (it is a
        // wake source only; the data plane is the events region). poll()
        // reports ready only at the instant of a publish edge, so a missed
        // edge would never re-assert. We therefore poll with a timeout and
        // scan the events region on BOTH an edge and a timeout: the edge
        // makes us responsive, the timeout guarantees we never miss a burst
        // of coalesced events. We do NOT read() the cdev (it has no d_read).
        _ = posix.poll(&fds, 250) catch break;
        if (ctx.stop.load(.acquire)) break;

        const n = scanNewXruns(&region, &last_seq);
        if (n > 0) {
            const total = ctx.xrun_count.fetchAdd(n, .monotonic) + n;
            std.debug.print("semasound: xrun observed (+{d}, total {d}); continuing\n", .{ n, total });
        }
    }
}

// Read the whole events region into `region` via a fresh open (offset 0),
// using only the confirmed posix.open/read/close idioms (no pread/lseek).
// Returns the bytes read, or null on failure.
fn readRegion(region: *[REGION_SIZE]u8) ?usize {
    const efd = posix.open(protocol.EVENTS_PATH, .{ .ACCMODE = .RDONLY }, 0) catch return null;
    defer posix.close(efd);
    var off: usize = 0;
    while (off < REGION_SIZE) {
        const n = posix.read(efd, region[off..]) catch break;
        if (n == 0) break;
        off += n;
    }
    return off;
}

fn readWriterSeq(region: *[REGION_SIZE]u8) ?u64 {
    const got = readRegion(region) orelse return null;
    if (got < HEADER_SIZE) return null;
    const hdr: *const Header = @ptrCast(@alignCast(region));
    if (hdr.magic != EVENTS_MAGIC) return null;
    return hdr.writer_seq;
}

// Read the region, count STREAM/XRUN slots with seq > last_seq, advance
// last_seq to the current writer_seq. Returns the number of new xruns.
fn scanNewXruns(region: *[REGION_SIZE]u8, last_seq: *u64) u64 {
    const got = readRegion(region) orelse return 0;
    if (got < HEADER_SIZE) return 0;
    const hdr: *const Header = @ptrCast(@alignCast(region));
    if (hdr.magic != EVENTS_MAGIC) return 0;

    const writer_seq = hdr.writer_seq;
    if (writer_seq <= last_seq.*) {
        last_seq.* = writer_seq;
        return 0;
    }

    var count: u64 = 0;
    const slots_base = HEADER_SIZE;
    var i: usize = 0;
    while (i < SLOT_COUNT) : (i += 1) {
        const off = slots_base + i * SLOT_SIZE;
        const slot: *const Slot = @ptrCast(@alignCast(region[off .. off + SLOT_SIZE]));
        if (slot.seq > last_seq.* and slot.seq <= writer_seq and
            slot.source_role == ROLE_STREAM and slot.event_type == EVTYPE_XRUN)
        {
            count += 1;
        }
    }
    last_seq.* = writer_seq;
    return count;
}
