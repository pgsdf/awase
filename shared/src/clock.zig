const std = @import("std");
const posix = std.posix;

// ============================================================================
// Clock region layout
// ============================================================================
//
// The clock region is a 20-byte memory-mapped file at /var/run/sema/clock.
// The production writer is audiofs (kernel, ADR 0018); ClockWriter below is
// retained as a test and diagnostic fixture. All daemons and chronofs read it.
//
// Offset  Size  Field           Description
// ------  ----  -----           -----------
//  0       4    magic           0x534D434B ("SMCK") little-endian
//  4       1    version         Region format version (currently 1)
//  5       1    clock_valid     0 = no stream ever started, 1 = clock is live
//  6       1    clock_source    0 = invalid/unset, 1 = audio (default),
//                                2 = wall (reserved), 3 = tsc (reserved)
//  7       1    _pad            Reserved, must be zero
//  8       4    sample_rate     Sample frames per second of the active stream
// 12       8    samples_written Monotonic PCM sample frame counter (atomic u64)
//
// Total: 20 bytes. The u64 at offset 12 is NOT naturally aligned (offset 12 is
// a 4-byte boundary). Its store is single-copy-atomic only because the region
// is mapped page-aligned, keeping bytes 12-19 within one cache line; on amd64
// an unaligned store that does not cross a cache line is atomic. This is an
// amd64-scoped guarantee. See shared/CLOCK.md "Region layout" for the
// non-x86/aarch64 caveat and the version-bump that would fix it.
//
// clock_source is observability metadata, not a fallback selector. UTF's
// clock is audio-driven by construction (see docs/Thoughts.md and
// docs/UTF_ARCHITECTURAL_DISCIPLINE.md). The field exists so readers and
// diagnostic tools can identify which writer produced the region without
// guessing. Values 2 (wall) and 3 (tsc) are reserved for future writers
// that may exist in test scaffolding or alternative builds; they are not
// used by the canonical UTF stack and do not enable runtime fallback.
//
// The field was promoted from the previously-reserved _pad byte at offset
// 6 without bumping version. Old writers (which wrote 0 at this offset)
// remain compatible: their value is read as "invalid/unset" which is
// accurate semantics for legacy data. Old readers (which ignored the byte)
// remain compatible: they continue to ignore it.
//
// Concurrency model:
//   samples_written is published by a single little-endian u64 store and read
//   with SeqCst atomics by all readers. No mutex is required. The store is
//   single-copy-atomic on amd64 by the within-cache-line guarantee noted under
//   the layout above, not by natural alignment.
//   clock_valid is written once (0 → 1) and never reset. clock_source is
//   written by streamBegin alongside clock_valid; readers that see
//   clock_valid = 1 also see the matching clock_source, courtesy of the
//   release store on clock_valid.

pub const CLOCK_PATH = "/var/run/sema/clock";
pub const CLOCK_MAGIC: u32 = 0x534D434B; // "SMCK"
pub const CLOCK_VERSION: u8 = 1;
pub const CLOCK_SIZE: usize = 20;

// clock_source values.
pub const CLOCK_SOURCE_INVALID: u8 = 0;
pub const CLOCK_SOURCE_AUDIO: u8 = 1;
pub const CLOCK_SOURCE_WALL: u8 = 2; // reserved, not used by canonical UTF
pub const CLOCK_SOURCE_TSC: u8 = 3; // reserved, not used by canonical UTF

// Byte offsets within the region.
const OFF_MAGIC: usize = 0;
const OFF_VERSION: usize = 4;
const OFF_VALID: usize = 5;
const OFF_SOURCE: usize = 6;
const OFF_PAD: usize = 7;
const OFF_SAMPLE_RATE: usize = 8;
const OFF_SAMPLES: usize = 12;

// ============================================================================
// ClockWriter — test and diagnostic fixture (production writer is audiofs)
// ============================================================================

/// Owns a memory-mapped clock file and publishes the audio clock position.
///
/// As of ADR 0018 (F.4) the production writer is audiofs in the kernel; this
/// type is retained as a test and diagnostic fixture. It is used by the
/// chronofs and semadraw test suites to lay down a clock region for exercising
/// ClockReader, and is available to standalone diagnostic tools. It is no
/// longer wired into any production daemon (the production writer is
/// the audiofs kernel module since F.4, ADR 0018).
/// Raw open/size helpers. Zig 0.16 removed the std.fs.*Absolute wrappers and
/// the std.posix.open/close/ftruncate/lseek wrappers, relocating file I/O under
/// std.Io. clock.zig is a raw-descriptor and mmap subsystem (it already owns
/// posix.mmap/munmap directly), so per ADR shared 0001 and 0002 it adapts to
/// the surviving posix.system primitives rather than taking on std.Io and an Io
/// handle. These keep the path null-termination and error check in one place;
/// the public ClockReader/ClockWriter interfaces are unchanged.
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

pub const ClockWriter = struct {
    map: []u8,
    fd: posix.fd_t,

    /// Open or create the clock file and mmap it.
    /// Creates /var/run/sema/ if absent.
    pub fn init(path: []const u8) !ClockWriter {
        // Ensure parent directory exists. Best effort: if it cannot be created
        // (including because it already exists), a genuine failure surfaces at
        // the open below.
        if (std.fs.path.dirname(path)) |dir_path| {
            var dir_buf = posix.toPosixPath(dir_path) catch return error.NameTooLong;
            _ = posix.system.mkdir(&dir_buf, 0o755);
        }

        // Open or create the file. Mode 0o600 per ADR 0013;
        // operators override via daemon's process group and umask.
        const raw_fd = try openCreateRdwr(path, 0o600);
        errdefer _ = posix.system.close(raw_fd);

        // Size the file.
        if (posix.system.ftruncate(raw_fd, @intCast(CLOCK_SIZE)) != 0) return error.TruncateFailed;

        // Map it read-write.
        const map_raw = try posix.mmap(
            null,
            CLOCK_SIZE,
            .{ .READ = true, .WRITE = true },
            .{ .TYPE = .SHARED },
            raw_fd,
            0,
        );
        errdefer posix.munmap(map_raw);

        const map: []u8 = map_raw[0..CLOCK_SIZE];
        const writer = ClockWriter{ .map = map, .fd = raw_fd };

        // Write the static header fields.
        writer.writeU32(OFF_MAGIC, CLOCK_MAGIC);
        writer.map[OFF_VERSION] = CLOCK_VERSION;
        writer.map[OFF_VALID] = 0; // not valid until first stream
        writer.map[OFF_SOURCE] = CLOCK_SOURCE_INVALID; // set by streamBegin
        writer.map[OFF_PAD] = 0;
        writer.writeU32(OFF_SAMPLE_RATE, 0);
        writer.writeU64Atomic(OFF_SAMPLES, 0);

        return writer;
    }

    pub fn deinit(self: ClockWriter) void {
        posix.munmap(@alignCast(self.map));
        _ = posix.system.close(self.fd);
    }

    /// Called when a stream begins. Sets sample_rate and marks the clock valid.
    /// Must be called before the first update().
    ///
    /// Also stamps clock_source = CLOCK_SOURCE_AUDIO. The store on
    /// clock_valid (sequentially consistent, written last) provides the
    /// happens-before edge that guarantees readers seeing clock_valid = 1
    /// also see the matching clock_source.
    pub fn streamBegin(self: ClockWriter, sample_rate: u32) void {
        self.writeU32(OFF_SAMPLE_RATE, sample_rate);
        self.map[OFF_SOURCE] = CLOCK_SOURCE_AUDIO;
        // Mark valid last; readers check clock_valid before reading samples.
        @atomicStore(u8, &self.map[OFF_VALID], 1, .seq_cst);
    }

    /// Update the monotonic sample counter. Call after each posix.write() to
    /// the OSS device. `total_samples` is the cumulative count, not a delta.
    pub fn update(self: ClockWriter, total_samples: u64) void {
        self.writeU64Atomic(OFF_SAMPLES, total_samples);
    }

    // -----------------------------------------------------------------------

    fn writeU32(self: ClockWriter, off: usize, v: u32) void {
        std.mem.writeInt(u32, self.map[off..][0..4], v, .little);
    }

    fn writeU64Atomic(self: ClockWriter, off: usize, v: u64) void {
        // writeInt handles any byte alignment of the underlying []u8 slice.
        // The field at offset 12 is NOT naturally aligned; its store is
        // single-copy-atomic only because the mmap is page-aligned, keeping
        // bytes 12-19 within one cache line, and amd64 makes a within-cache-line
        // unaligned store atomic. This is amd64-scoped (see the layout comment
        // and shared/CLOCK.md). The release store on clock_valid (written last
        // in streamBegin) provides ordering for readers that check clock_valid
        // before reading this field.
        std.mem.writeInt(u64, self.map[off..][0..8], v, .little);
    }
};

// ============================================================================
// ClockReader — used by semainput, semadraw, chronofs
// ============================================================================

/// Reads the shared clock region. Open is non-fatal: if the file is absent
/// (clock writer not running), isValid() returns false and read() returns 0.
pub const ClockReader = struct {
    map: ?[]const u8,
    fd: posix.fd_t,

    /// Attempt to open the clock file. Does not fail if absent.
    pub fn init(path: []const u8) ClockReader {
        const raw_fd = openReadOnly(path) catch {
            return .{ .map = null, .fd = -1 };
        };

        // Defensive size check before mmap. mmap with a length larger
        // than the backing file's size succeeds, but reads past the
        // file's actual end fault SIGBUS/SIGSEGV. This commonly happens
        // during the writer's bringup window: createFileAbsolute(truncate=true)
        // produces a 0-byte file before setEndPos grows it; if a reader
        // (e.g. semadrawd's frame scheduler) opens during that window,
        // every byte read past the actual file end is a fault. Treat
        // "file too short" identically to "file does not exist" so the
        // caller's existing wall-clock-fallback path takes over.
        const end_pos = fileSize(raw_fd) catch {
            _ = posix.system.close(raw_fd);
            return .{ .map = null, .fd = -1 };
        };
        if (end_pos < @as(u64, CLOCK_SIZE)) {
            _ = posix.system.close(raw_fd);
            return .{ .map = null, .fd = -1 };
        }

        const map_raw = posix.mmap(
            null,
            CLOCK_SIZE,
            .{ .READ = true },
            .{ .TYPE = .SHARED },
            raw_fd,
            0,
        ) catch {
            _ = posix.system.close(raw_fd);
            return .{ .map = null, .fd = -1 };
        };

        const map: []const u8 = map_raw[0..CLOCK_SIZE];

        // Validate magic and version before trusting the region.
        const magic = std.mem.readInt(u32, map[OFF_MAGIC..][0..4], .little);
        if (magic != CLOCK_MAGIC or map[OFF_VERSION] != CLOCK_VERSION) {
            posix.munmap(@alignCast(map_raw));
            _ = posix.system.close(raw_fd);
            return .{ .map = null, .fd = -1 };
        }

        return .{ .map = map, .fd = raw_fd };
    }

    pub fn deinit(self: ClockReader) void {
        if (self.map) |m| posix.munmap(@alignCast(@constCast(m)));
        if (self.fd >= 0) _ = posix.system.close(self.fd);
    }

    /// True if the clock file is open, valid, and at least one audio stream
    /// has started (i.e. samples_written is meaningful).
    pub fn isValid(self: ClockReader) bool {
        const m = self.map orelse return false;
        return @atomicLoad(u8, &m[OFF_VALID], .seq_cst) != 0;
    }

    /// Read the current sample position. Returns 0 if the clock is not valid.
    pub fn read(self: ClockReader) u64 {
        const m = self.map orelse return 0;
        if (@atomicLoad(u8, &m[OFF_VALID], .seq_cst) == 0) return 0;
        return std.mem.readInt(u64, m[OFF_SAMPLES..][0..8], .little);
    }

    /// Read the sample rate of the active stream. Returns 0 if not valid.
    pub fn sampleRate(self: ClockReader) u32 {
        const m = self.map orelse return 0;
        if (@atomicLoad(u8, &m[OFF_VALID], .seq_cst) == 0) return 0;
        return std.mem.readInt(u32, m[OFF_SAMPLE_RATE..][0..4], .little);
    }

    /// Read the clock source identifier. Observability metadata only;
    /// readers should not switch behaviour based on this value.
    /// Returns CLOCK_SOURCE_INVALID if the file is not open or the writer
    /// has not yet called streamBegin.
    ///
    /// Possible return values:
    ///   CLOCK_SOURCE_INVALID (0): file open but no stream has started yet,
    ///       or writer is a legacy version that did not set this field.
    ///   CLOCK_SOURCE_AUDIO   (1): canonical UTF audio-driven clock.
    ///   CLOCK_SOURCE_WALL    (2): reserved; not used by canonical UTF.
    ///   CLOCK_SOURCE_TSC     (3): reserved; not used by canonical UTF.
    pub fn source(self: ClockReader) u8 {
        const m = self.map orelse return CLOCK_SOURCE_INVALID;
        return m[OFF_SOURCE];
    }
};

// ============================================================================
// toNanoseconds
// ============================================================================

/// Convert a sample position to nanoseconds.
/// Uses u128 intermediate to avoid overflow at large sample counts.
/// At 48kHz, u64 samples overflow after ~384,000 years, so overflow of
/// the final u64 result is not a practical concern.
pub fn toNanoseconds(samples: u64, sample_rate: u32) u64 {
    if (sample_rate == 0) return 0;
    const ns = (@as(u128, samples) * 1_000_000_000) / @as(u128, sample_rate);
    return @intCast(@min(ns, std.math.maxInt(u64)));
}

// ============================================================================
// Tests
// ============================================================================

test "toNanoseconds basic" {
    // 48000 samples at 48kHz = exactly 1 second = 1_000_000_000 ns
    try std.testing.expectEqual(
        @as(u64, 1_000_000_000),
        toNanoseconds(48_000, 48_000),
    );

    // 0 samples = 0 ns
    try std.testing.expectEqual(@as(u64, 0), toNanoseconds(0, 48_000));

    // 0 sample_rate = 0 ns (guard against division by zero)
    try std.testing.expectEqual(@as(u64, 0), toNanoseconds(48_000, 0));

    // 96000 samples at 48kHz = 2 seconds
    try std.testing.expectEqual(
        @as(u64, 2_000_000_000),
        toNanoseconds(96_000, 48_000),
    );

    // 44100 samples at 44100Hz = exactly 1 second
    try std.testing.expectEqual(
        @as(u64, 1_000_000_000),
        toNanoseconds(44_100, 44_100),
    );
}

test "toNanoseconds no overflow at large sample counts" {
    // 2^63 samples at 48kHz — should not panic or wrap
    const large: u64 = std.math.maxInt(u64) / 2;
    const result = toNanoseconds(large, 48_000);
    try std.testing.expect(result > 0);
}

test "ClockWriter and ClockReader two-thread atomic visibility" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var io_backing = std.Io.Threaded.init(std.testing.allocator, .{});
    defer io_backing.deinit();
    const io = io_backing.io();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_len = try tmp.dir.realPath(io, &path_buf);
    const tmp_path = path_buf[0..tmp_len];
    var full_buf: [std.fs.max_path_bytes]u8 = undefined;
    const clock_path = try std.fmt.bufPrint(&full_buf, "{s}/clock", .{tmp_path});

    // Writer side: init, stream begins, write samples.
    var writer = try ClockWriter.init(clock_path);
    defer writer.deinit();

    // Before streamBegin: clock_valid must be 0.
    var reader = ClockReader.init(clock_path);
    defer reader.deinit();
    try std.testing.expect(!reader.isValid());
    try std.testing.expectEqual(@as(u64, 0), reader.read());
    // Source is invalid until streamBegin sets it.
    try std.testing.expectEqual(CLOCK_SOURCE_INVALID, reader.source());

    // Simulate stream begin at 48kHz.
    writer.streamBegin(48_000);
    try std.testing.expect(reader.isValid());
    try std.testing.expectEqual(@as(u32, 48_000), reader.sampleRate());
    try std.testing.expectEqual(@as(u64, 0), reader.read());
    // Source is now audio.
    try std.testing.expectEqual(CLOCK_SOURCE_AUDIO, reader.source());

    // Write sample counts and confirm reader sees them.
    writer.update(1_000);
    try std.testing.expectEqual(@as(u64, 1_000), reader.read());

    writer.update(48_000);
    try std.testing.expectEqual(@as(u64, 48_000), reader.read());

    writer.update(std.math.maxInt(u64) / 2);
    try std.testing.expectEqual(std.math.maxInt(u64) / 2, reader.read());
}

test "ClockReader is non-fatal when file absent" {
    const reader = ClockReader.init("/var/run/sema/clock_does_not_exist_test");
    defer reader.deinit();
    try std.testing.expect(!reader.isValid());
    try std.testing.expectEqual(@as(u64, 0), reader.read());
    try std.testing.expectEqual(@as(u32, 0), reader.sampleRate());
}

test "ClockWriter creates parent directory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var io_backing = std.Io.Threaded.init(std.testing.allocator, .{});
    defer io_backing.deinit();
    const io = io_backing.io();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_len = try tmp.dir.realPath(io, &path_buf);
    const tmp_path = path_buf[0..tmp_len];
    var full_buf: [std.fs.max_path_bytes]u8 = undefined;
    // Subdirectory that doesn't exist yet.
    const clock_path = try std.fmt.bufPrint(&full_buf, "{s}/sema/clock", .{tmp_path});

    var writer = try ClockWriter.init(clock_path);
    writer.deinit();

    // Confirm the file exists and is the correct size.
    var check = try tmp.dir.openFile("sema/clock", .{});
    defer check.close();
    const stat = try check.stat();
    try std.testing.expectEqual(@as(u64, CLOCK_SIZE), stat.size);
}

test "ClockReader rejects wrong magic" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var io_backing = std.Io.Threaded.init(std.testing.allocator, .{});
    defer io_backing.deinit();
    const io = io_backing.io();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_len = try tmp.dir.realPath(io, &path_buf);
    const tmp_path = path_buf[0..tmp_len];
    var full_buf: [std.fs.max_path_bytes]u8 = undefined;
    const clock_path = try std.fmt.bufPrint(&full_buf, "{s}/clock", .{tmp_path});

    // Write a file with wrong magic.
    var f = try tmp.dir.createFile("clock", .{});
    try f.writeAll(&[_]u8{0} ** CLOCK_SIZE);
    f.close();

    const reader = ClockReader.init(clock_path);
    defer reader.deinit();
    try std.testing.expect(!reader.isValid());
}
