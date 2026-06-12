// F.5.a client model (ADR 0021 Decision 2).
//
// Each accepted connection occupies a fixed slot in the ClientSet, owns an
// input Ring, and is fed by a reader thread that copies socket PCM into the
// ring until EOF. The mixer/output thread (increment 3) drains rings via
// ClientSet.forEachActive. Slots are fixed (no per-connection allocation),
// so reader threads hold a stable pointer for their lifetime; a slot is
// reclaimed only after its reader has exited and its ring has drained.

const std = @import("std");
const posix = std.posix;
const Ring = @import("ring.zig").Ring;
const protocol = @import("protocol.zig");
const resampler_mod = @import("resampler.zig");

pub const MAX_CLIENTS: usize = 16;

pub const Client = struct {
    id: u32 = 0,
    fd: posix.fd_t = -1,
    ring: Ring = .{},
    closed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    thread: ?std.Thread = null,

    // F.5.b per-client format adaptation. The client's declared input format,
    // captured at connect from the Hello. Used by the reader thread to decide
    // resampling and mono->stereo duplication.
    in_rate: u32 = protocol.CANON_RATE,
    in_channels: u16 = 2,

    // F.5.d (ADR 0026 Decision 5): set at admission when the client's class
    // is an override class on its target. Read by the output pass to compute
    // reference-counted ducking. Written once before the reader starts; a
    // sub-chunk window where a freshly admitted client is mixed one pass at
    // the prior gain state is accepted (a gain ramp, not a correctness
    // hazard).
    override_member: bool = false,

    // F.5.e (ADR 0027): the client's declared identity, stored at admission
    // for the `clients` surface and reap events. NUL-padded like the wire
    // fields; set once before the reader starts.
    label_buf: [16]u8 = [_]u8{0} ** 16,
    class_buf: [16]u8 = [_]u8{0} ** 16,

    // The resampler instance. OWNERSHIP: the client's own reader thread is the
    // SOLE mutator of this structure (init at connect, run each iteration,
    // rebuild on a future election change). No other thread swaps or reinits
    // it, so there is no pointer-swap race; the single-writer invariant holds
    // by construction. null means the bit-exact passthrough case (input rate
    // already equals the hardware rate AND stereo): the reader pushes raw
    // frames and the mixer reads them directly, exactly as F.5.a.
    resampler: ?resampler_mod.Resampler = null,

    // The shared output-domain drift trim, written by the estimator thread,
    // read by the reader thread before each resample. This is the ONLY
    // cross-thread touch of resampler-related state: a single atomic scalar,
    // not a structural mutation, so it needs no lock and cannot race the
    // reader's ownership of the resampler instance. Stored as bits of an f64.
    trim_bits: std.atomic.Value(u64) = std.atomic.Value(u64).init(@bitCast(@as(f64, 1.0))),

    pub fn setTrim(self: *Client, trim: f64) void {
        self.trim_bits.store(@bitCast(trim), .monotonic);
    }
    pub fn getTrim(self: *const Client) f64 {
        return @bitCast(self.trim_bits.load(.monotonic));
    }

    // F.5.e identity accessors (declarations must follow all container
    // fields in Zig; the fields live above with the other per-client state).
    pub fn setIdentity(self: *Client, label: []const u8, class: []const u8) void {
        const ln = @min(label.len, self.label_buf.len);
        @memcpy(self.label_buf[0..ln], label[0..ln]);
        const cn = @min(class.len, self.class_buf.len);
        @memcpy(self.class_buf[0..cn], class[0..cn]);
    }
    pub fn labelSlice(self: *const Client) []const u8 {
        var end: usize = self.label_buf.len;
        while (end > 0 and self.label_buf[end - 1] == 0) end -= 1;
        if (end == 0) return "anon";
        return self.label_buf[0..end];
    }
    pub fn classSlice(self: *const Client) []const u8 {
        var end: usize = self.class_buf.len;
        while (end > 0 and self.class_buf[end - 1] == 0) end -= 1;
        if (end == 0) return "none";
        return self.class_buf[0..end];
    }
};

/// Reader thread body: copy socket PCM into the ring until EOF or error.
// Reader thread. Reads native-format PCM from the client socket, adapts it to
// the hardware format (mono->stereo duplication, then resampling if the
// client's rate differs from the elected hardware rate), and pushes
// hardware-rate stereo frames into the ring. The mixer therefore always sees
// hardware-rate stereo, unchanged from F.5.a.
//
// This thread is the SOLE mutator of client.resampler (single-writer
// invariant). The estimator thread only writes client.trim_bits (one atomic
// scalar), which this thread reads via getTrim before each resample call.
pub fn readerRun(client: *Client) void {
    var raw: [4096]u8 = undefined; // native bytes from the socket
    // Stereo staging buffer (after mono->stereo, before resample). Worst case
    // is mono input: 4096 raw bytes = 2048 mono frames -> 2048*4 = 8192 stereo
    // bytes.
    var stereo: [8192]u8 = undefined;
    // Resampler output staging. Worst case is mono at the lowest rate: 2048
    // mono frames upsampled 8000->48000 (6x) = 12288 frames = 49152 bytes,
    // plus a small margin for the fractional-position carry that can emit one
    // extra frame as the accumulated position crosses a sample boundary.
    var resampled: [49152 + 256]u8 = undefined;

    const stereo_in = (client.in_channels == 2);

    while (true) {
        const n = posix.read(client.fd, &raw) catch break;
        if (n == 0) break; // EOF: client closed

        // Frame-align the raw read to the input format's frame size.
        const in_bpf: usize = if (stereo_in) 4 else 2; // 16-bit
        const usable = n - (n % in_bpf);
        if (usable == 0) continue;

        // Step 1: produce 16-bit stereo (duplicate mono to both channels).
        var stereo_len: usize = undefined;
        if (stereo_in) {
            @memcpy(stereo[0..usable], raw[0..usable]);
            stereo_len = usable;
        } else {
            const frames = usable / 2;
            var i: usize = 0;
            while (i < frames) : (i += 1) {
                const lo = raw[i * 2];
                const hi = raw[i * 2 + 1];
                stereo[i * 4] = lo;
                stereo[i * 4 + 1] = hi;
                stereo[i * 4 + 2] = lo;
                stereo[i * 4 + 3] = hi;
            }
            stereo_len = frames * 4;
        }

        // Step 2: resample to hardware rate if a resampler is present, else
        // pass the stereo frames straight through (bit-exact passthrough).
        const out_bytes: []const u8 = blk: {
            if (client.resampler) |*rs| {
                // Apply the latest shared drift trim before converting. The
                // reader owns rs; the estimator only set the scalar trim.
                rs.setRatioTrim(client.getTrim());
                const wrote = rs.resample(stereo[0..stereo_len], &resampled);
                break :blk resampled[0..wrote];
            } else {
                break :blk stereo[0..stereo_len];
            }
        };

        if (out_bytes.len == 0) continue;
        if (!client.ring.pushBlocking(out_bytes, &client.stop)) break;
    }
    client.closed.store(true, .release);
}

pub const ClientSet = struct {
    clients: [MAX_CLIENTS]Client = [_]Client{.{}} ** MAX_CLIENTS,
    active: [MAX_CLIENTS]bool = [_]bool{false} ** MAX_CLIENTS,
    mutex: std.Thread.Mutex = .{},

    /// Claim a free slot for `fd`. Returns null if full (caller closes fd).
    pub fn add(self: *ClientSet, fd: posix.fd_t, id: u32) ?*Client {
        self.mutex.lock();
        defer self.mutex.unlock();
        var i: usize = 0;
        while (i < MAX_CLIENTS) : (i += 1) {
            if (!self.active[i]) {
                self.clients[i] = .{ .id = id, .fd = fd };
                self.active[i] = true;
                return &self.clients[i];
            }
        }
        return null;
    }

    /// Reclaim slots whose reader has exited and whose ring has drained:
    /// join the reader, close the fd, free the slot.
    /// Reap finished clients, reporting the ids of reaped slots into
    /// out_ids (F.5.e: callers append reaped events; the event append is
    /// the caller's, so this function stays free of observability work).
    pub fn reap(self: *ClientSet, out_ids: []u32) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        var nreaped: usize = 0;
        var i: usize = 0;
        while (i < MAX_CLIENTS) : (i += 1) {
            if (self.active[i] and
                self.clients[i].closed.load(.acquire) and
                self.clients[i].ring.available() == 0)
            {
                if (self.clients[i].thread) |t| t.join();
                posix.close(self.clients[i].fd);
                self.active[i] = false;
                if (nreaped < out_ids.len) {
                    out_ids[nreaped] = self.clients[i].id;
                    nreaped += 1;
                }
            }
        }
        return nreaped;
    }

    /// Call `f(ctx, *Client)` for each active slot, under the set lock.
    pub fn forEachActive(
        self: *ClientSet,
        ctx: anytype,
        comptime f: fn (@TypeOf(ctx), *Client) void,
    ) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        var i: usize = 0;
        while (i < MAX_CLIENTS) : (i += 1) {
            if (self.active[i]) f(ctx, &self.clients[i]);
        }
    }

    pub fn activeCount(self: *ClientSet) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        var c: usize = 0;
        for (self.active) |a| {
            if (a) c += 1;
        }
        return c;
    }

    /// Fill `out` with pointers to active clients; returns the count. The
    /// output thread snapshots under the lock, then pops rings outside it.
    /// Safe because reap (the only slot reclaimer) runs in that same thread.
    pub fn snapshotActive(self: *ClientSet, out: []*Client) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        var k: usize = 0;
        var i: usize = 0;
        while (i < MAX_CLIENTS and k < out.len) : (i += 1) {
            if (self.active[i]) {
                out[k] = &self.clients[i];
                k += 1;
            }
        }
        return k;
    }

    /// Signal all readers to stop (used on shutdown).
    pub fn stopAll(self: *ClientSet) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        var i: usize = 0;
        while (i < MAX_CLIENTS) : (i += 1) {
            if (self.active[i]) self.clients[i].stop.store(true, .release);
        }
    }
};
