//! compat.fs: Awase-owned filesystem boundary.
//!
//! Zig 0.16 relocated the filesystem under std.Io: std.fs.cwd/File/Dir moved to
//! std.Io.Dir/File, every file operation takes an Io handle, and byte transfer
//! goes through the std.Io Reader/Writer interface rather than File.read/write.
//! This module owns that surface so application code keeps pre-0.16 ergonomics
//! and never references std.Io.Dir, std.Io.File, std.Io.Reader, or std.Io.Writer
//! directly (ADR shared 0001, Decisions 2 and 3). The Io handle is carried
//! inside Dir and File, so no call site threads an io argument through
//! individual operations.
//!
//! Scope is deliberately the minimum the 0.16 migration needs (ADR shared 0001,
//! Decision 5): create-or-open, write a byte slice, read into a byte slice,
//! query and set the write position (for the placeholder-then-backfill pattern
//! in the SDCS encoder), and close. A File is used for writing or for reading,
//! not both. A second pass can widen this surface once the tree is green.

const std = @import("std");

/// Per-file staging buffer for the Io Reader/Writer interface. Writes flush
/// after each call so the reported position is always exact, which the
/// encoder's offset bookkeeping depends on; the buffer therefore only batches
/// within a single writeAll and its size is not correctness-relevant.
const buffer_size = 4096;

/// Options for creating a file. Mirrors only the create mode the tree uses.
pub const CreateOptions = struct {
    /// Truncate an existing regular file to zero length on open.
    truncate: bool = true,
};

/// A directory handle bound to an Io context. Obtain via `cwd`.
pub const Dir = struct {
    inner: std.Io.Dir,
    io: std.Io,

    /// Create (or truncate) a file for writing.
    pub fn createFile(self: Dir, sub_path: []const u8, options: CreateOptions) !File {
        const f = try self.inner.createFile(self.io, sub_path, .{ .truncate = options.truncate });
        return .{ .inner = f, .io = self.io };
    }

    /// Open an existing file for reading.
    pub fn openFile(self: Dir, sub_path: []const u8) !File {
        const f = try self.inner.openFile(self.io, sub_path, .{});
        return .{ .inner = f, .io = self.io };
    }
};

/// The current working directory, bound to `io`.
pub fn cwd(io: std.Io) Dir {
    return .{ .inner = std.Io.Dir.cwd(), .io = io };
}

/// An open file bound to an Io context, used for writing or for reading but not
/// both. It holds the Reader/Writer state inline, so once any operation has run
/// it must be referenced by pointer and must not be copied. Call `close`
/// exactly once.
///
/// The buffered Reader/Writer recover their parent through @fieldParentPtr on a
/// static vtable, so storing them here by value is move-safe as long as the
/// File itself stays pinned for the duration of use.
pub const File = struct {
    inner: std.Io.File,
    io: std.Io,
    w: ?std.Io.File.Writer = null,
    r: ?std.Io.File.Reader = null,
    buf: [buffer_size]u8 = undefined,

    fn writerRef(self: *File) *std.Io.File.Writer {
        if (self.w == null) self.w = self.inner.writer(self.io, &self.buf);
        return &self.w.?;
    }

    fn readerRef(self: *File) *std.Io.File.Reader {
        if (self.r == null) self.r = self.inner.reader(self.io, &self.buf);
        return &self.r.?;
    }

    /// Write the whole slice at the current write position, then flush so the
    /// position is exact for any following getPos. The concrete file error is
    /// recovered from the writer when the interface reports a generic failure.
    pub fn writeAll(self: *File, bytes: []const u8) !void {
        const wr = self.writerRef();
        wr.interface.writeAll(bytes) catch |e| return wr.err orelse e;
        wr.interface.flush() catch |e| return wr.err orelse e;
    }

    /// Byte offset of the next write. Used by the encoder to record chunk
    /// offsets before backfilling a header.
    pub fn getPos(self: *File) u64 {
        return self.writerRef().pos;
    }

    /// Reposition the write cursor, for placeholder-then-backfill writes.
    pub fn seekTo(self: *File, offset: u64) !void {
        try self.writerRef().seekTo(offset);
    }

    /// Read up to dest.len bytes; returns the count read, 0 at end of file.
    pub fn read(self: *File, dest: []u8) !usize {
        return self.readerRef().interface.readSliceShort(dest);
    }

    /// Read exactly dest.len bytes; errors if end of file comes first.
    pub fn readExact(self: *File, dest: []u8) !void {
        try self.readerRef().interface.readSliceAll(dest);
    }

    /// Flush any pending write and close. Deliberately does not finalize the
    /// writer with end(): end() sets the file length to the current write
    /// cursor, but the encoder seeks backward to rewrite a header, so the
    /// cursor is not at end of file. Flushing alone leaves the file at the
    /// highest written offset, which is correct.
    pub fn close(self: *File) void {
        if (self.w) |*wr| wr.interface.flush() catch {};
        self.inner.close(self.io);
    }
};
