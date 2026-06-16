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

/// posix_safe (AD-6) owns fd-level read/write over posix.system. The console
/// streams below reuse it so stdout/stderr writes do not depend on the volatile
/// std.Io writer path (ADR shared 0001, route A for console output).
const posix_safe = @import("../posix_safe.zig");

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

/// Options for opening a directory. Mirrors only the iterate flag the tree
/// uses; a Dir must be opened with iterate = true before `iterate` is called.
pub const OpenDirOptions = struct {
    iterate: bool = false,
};

/// A directory entry yielded by `Iterator.next`. Aliased so call sites name the
/// type through compat.fs rather than std.Io.Dir.
pub const Entry = std.Io.Dir.Entry;

/// File metadata returned by `File.stat`. Aliased so call sites name the type
/// through compat.fs rather than std.Io.File.
pub const Stat = std.Io.File.Stat;

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

    /// Check that a path exists and is accessible (relative to this Dir, or
    /// absolute). Errors if it cannot be accessed; used for existence tests.
    pub fn access(self: Dir, sub_path: []const u8) !void {
        try self.inner.access(self.io, sub_path, .{});
    }

    /// Open a subdirectory. Pass `.{ .iterate = true }` to allow `iterate`.
    pub fn openDir(self: Dir, sub_path: []const u8, options: OpenDirOptions) !Dir {
        const d = try self.inner.openDir(self.io, sub_path, .{ .iterate = options.iterate });
        return .{ .inner = d, .io = self.io };
    }

    /// Iterate this directory's entries. The Dir must have been opened with
    /// `.iterate = true`. The returned Iterator carries the Io handle, so its
    /// `next` takes no argument.
    pub fn iterate(self: Dir) Iterator {
        return .{ .inner = self.inner.iterate(), .io = self.io };
    }

    /// Create a subdirectory with the platform default directory permissions.
    /// 0.16 renamed makeDir to createDir and made the mode explicit; this keeps
    /// the makeDir name and supplies .default_dir.
    pub fn makeDir(self: Dir, sub_path: []const u8) !void {
        try self.inner.createDir(self.io, sub_path, .default_dir);
    }

    /// Recursively delete a subtree. Used by test scaffolding to clean tmp dirs.
    pub fn deleteTree(self: Dir, sub_path: []const u8) !void {
        try self.inner.deleteTree(self.io, sub_path);
    }

    /// Delete a single file (relative to this Dir, or absolute). Used for unix
    /// socket path cleanup. Distinct from deleteTree, which is recursive.
    pub fn deleteFile(self: Dir, sub_path: []const u8) !void {
        try self.inner.deleteFile(self.io, sub_path);
    }

    /// Close a directory handle obtained from `openDir`. The cwd handle from
    /// `cwd` is not owned and does not need closing.
    pub fn close(self: Dir) void {
        self.inner.close(self.io);
    }
};

/// An iterator over a Dir's entries, carrying the Io handle so `next` takes no
/// argument. Obtain via `Dir.iterate`; the source Dir must outlive it.
pub const Iterator = struct {
    inner: std.Io.Dir.Iterator,
    io: std.Io,

    /// The next entry, or null at end of directory.
    pub fn next(self: *Iterator) !?Entry {
        return self.inner.next(self.io);
    }
};

/// The current working directory, bound to `io`.
pub fn cwd(io: std.Io) Dir {
    return .{ .inner = std.Io.Dir.cwd(), .io = io };
}

/// Open an existing file by absolute path, bound to `io`. For regular-file
/// reads with no owning Dir handle, e.g. a cross-process artifact at a fixed
/// path. The path must be absolute. Device descriptors use raw openat, not
/// this (ADR shared 0001: device-fd acquisition stays in the raw-fd lineage).
pub fn openFileAbsolute(io: std.Io, absolute_path: []const u8) !File {
    const f = try std.Io.Dir.openFileAbsolute(io, absolute_path, .{});
    return .{ .inner = f, .io = io };
}

/// Create (or truncate) a file by absolute path, bound to `io`. For
/// regular-file writes with no owning Dir handle. The path must be absolute.
pub fn createFileAbsolute(io: std.Io, absolute_path: []const u8, options: CreateOptions) !File {
    const f = try std.Io.Dir.createFileAbsolute(io, absolute_path, .{ .truncate = options.truncate });
    return .{ .inner = f, .io = io };
}

/// A console output stream (stdout or stderr). Conceptually a stream, not a
/// file: it is fd-backed and writes through posix_safe (AD-6), with no std.Io
/// writer and no Io handle. Obtain via stdout() or stderr().
pub const Stream = struct {
    fd: std.posix.fd_t,

    /// Write the whole slice, looping over short writes.
    pub fn writeAll(self: Stream, bytes: []const u8) !void {
        var written: usize = 0;
        while (written < bytes.len) {
            const n = try posix_safe.safeWrite(self.fd, bytes[written..]);
            if (n == 0) return error.WriteFailed;
            written += n;
        }
    }
};

/// The process stdout stream.
pub fn stdout() Stream {
    return .{ .fd = std.Io.File.stdout().handle };
}

/// The process stderr stream.
pub fn stderr() Stream {
    return .{ .fd = std.Io.File.stderr().handle };
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

    /// Read the rest of the file into a freshly allocated slice (caller frees),
    /// up to max_bytes. The File must be opened for reading.
    pub fn readToEndAlloc(self: *File, gpa: std.mem.Allocator, max_bytes: usize) ![]u8 {
        return self.readerRef().interface.allocRemaining(gpa, std.Io.Limit.limited(max_bytes));
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

    /// File metadata. Added solely to preserve externally visible behaviour:
    /// the session-file reader checks the size before reading so an oversized
    /// file surfaces FileTooLarge (ADR 0004), rather than being silently
    /// replaced by an allocator-limit error mid-read. This is not a
    /// general-purpose metadata surface; new callers should use the read
    /// helpers above unless they specifically need the pre-read size check.
    pub fn stat(self: *File) !Stat {
        return self.inner.stat(self.io);
    }
};
