// pgsd-sessiond/src/session_file.zig
//
// Stage 4: full ADR 0004 parser and enumeration for .session files.
//
// Replaces the minimal Exec-only parser that lived in launch.zig
// during stage 3. This module owns:
//
//   - The SessionFile struct: id, name, exec, comment.
//   - parseSessionFile: parse a single file's contents.
//   - lookupById: read /usr/local/share/pgsd/sessions/<id>.session
//     and return a parsed SessionFile.
//   - enumerate: discover all valid .session files in the directory,
//     parse each, return a sorted list. Malformed files are skipped
//     with warnings appended to a caller-provided list rather than
//     written to stderr directly, so callers can format them.
//
// ADR 0004 §File grammar specifies:
//
//   file        ::= section+
//   section     ::= header line*
//   header      ::= '[' section_name ']' ws* EOL
//   line        ::= blank | comment | assignment
//   assignment  ::= key ws* '=' ws* value ws* EOL
//   key         ::= [A-Z] [A-Za-z0-9]*
//
// The v1 recognised section is `[PGSD Session]`. Required keys
// within: Name (1..256 bytes), Exec (1..4096 bytes). Optional:
// Comment (0..512 bytes). Unknown keys are accepted and ignored
// (forward compat). Unknown sections are accepted and ignored.
//
// Discovery rules (ADR 0004 §Discovery):
//
//   1. List entries in /usr/local/share/pgsd/sessions/.
//   2. Filter to those matching `[a-z][a-z0-9_-]*\.session$`.
//   3. Sort alphabetically by id.
//   4. For each file, parse. On failure, warning + skip.
//   5. Files lacking [PGSD Session], Name, or Exec are skipped.

const std = @import("std");

// =============================================================================
// Configuration
// =============================================================================

pub const DEFAULT_SESSIONS_DIR: []const u8 = "/usr/local/share/pgsd/sessions";

const SESSION_EXT: []const u8 = ".session";

// Per-file size cap. ADR 0004's Exec is up to 4096; Name 256;
// Comment 512; plus headers, blank lines, comments. 64 KiB is
// generous and bounds the allocation when parsing a malformed
// "session file" that's actually a binary blob someone dropped
// in the wrong directory.
const FILE_MAX: usize = 64 * 1024;

// Per-field size caps from ADR 0004.
const NAME_MAX: usize = 256;
const EXEC_MAX: usize = 4096;
const COMMENT_MAX: usize = 512;

// Per-id size cap. ADR 0004's id regex is `[a-z][a-z0-9_-]*` with
// no upper bound stated; 64 bytes is more than enough for any
// reasonable session id and limits stack-buffer sizes elsewhere.
const ID_MAX: usize = 64;

// =============================================================================
// Errors
// =============================================================================

pub const ParseError = error{
    NoPgsdSessionHeader,
    MissingName,
    MissingExec,
    EmptyName,
    EmptyExec,
    NameTooLong,
    ExecTooLong,
    CommentTooLong,
    InvalidKey,
    EmbeddedNul,
    OutOfMemory,
};

// =============================================================================
// SessionFile
// =============================================================================

pub const SessionFile = struct {
    id: []const u8, // owned, lowercase (e.g. "default")
    name: []const u8, // owned, 1..256 bytes
    exec: []const u8, // owned, 1..4096 bytes
    comment: ?[]const u8, // owned if present, 0..512 bytes

    pub fn deinit(self: *SessionFile, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.name);
        allocator.free(self.exec);
        if (self.comment) |c| allocator.free(c);
    }
};

// =============================================================================
// Enumeration result
// =============================================================================

/// Warning recorded during enumeration. Tied to a specific filename
/// so callers can format `warn (filename): reason` for the operator.
pub const Warning = struct {
    filename: []const u8, // owned
    reason: []const u8, // owned

    pub fn deinit(self: *Warning, allocator: std.mem.Allocator) void {
        allocator.free(self.filename);
        allocator.free(self.reason);
    }
};

pub const EnumerateResult = struct {
    sessions: std.ArrayListUnmanaged(SessionFile) = .empty,
    warnings: std.ArrayListUnmanaged(Warning) = .empty,

    pub fn deinit(self: *EnumerateResult, allocator: std.mem.Allocator) void {
        for (self.sessions.items) |*s| s.deinit(allocator);
        self.sessions.deinit(allocator);
        for (self.warnings.items) |*w| w.deinit(allocator);
        self.warnings.deinit(allocator);
    }
};

// =============================================================================
// id validation
// =============================================================================
//
// ADR 0004 §Discovery line 192: filter regex `[a-z][a-z0-9_-]*\.session$`.
// The id is the filename minus the .session suffix.

pub fn isValidSessionId(id: []const u8) bool {
    if (id.len == 0) return false;
    if (id.len > ID_MAX) return false;
    // First char: lowercase letter.
    if (id[0] < 'a' or id[0] > 'z') return false;
    // Rest: lowercase letter, digit, underscore, or hyphen.
    for (id[1..]) |ch| {
        const ok = (ch >= 'a' and ch <= 'z') or
            (ch >= '0' and ch <= '9') or
            ch == '_' or ch == '-';
        if (!ok) return false;
    }
    return true;
}

// =============================================================================
// Key validation per ADR 0004 grammar
// =============================================================================
//
// key ::= [A-Z] [A-Za-z0-9]*
// "PascalCase ASCII: first character uppercase, subsequent characters
//  letters or digits."

fn isValidKey(key: []const u8) bool {
    if (key.len == 0) return false;
    if (key[0] < 'A' or key[0] > 'Z') return false;
    for (key[1..]) |ch| {
        const ok = (ch >= 'A' and ch <= 'Z') or
            (ch >= 'a' and ch <= 'z') or
            (ch >= '0' and ch <= '9');
        if (!ok) return false;
    }
    return true;
}

// =============================================================================
// Per-file parser
// =============================================================================
//
// Walks lines, tracks which section we're in, captures Name/Exec/Comment
// inside [PGSD Session]. Returns a SessionFile with owned strings on
// success.
//
// The `id` is passed in by the caller (derived from the filename) and
// duped into the SessionFile. parseSessionFile itself does not derive
// id from content because ADR 0004 doesn't put id in the file body —
// id IS the filename minus .session.

pub fn parseSessionFile(
    allocator: std.mem.Allocator,
    id: []const u8,
    contents: []const u8,
) ParseError!SessionFile {
    var in_section = false;
    var found_header = false;

    // We collect Name/Exec/Comment values into stack-resident slices
    // first (pointing into `contents`), then dupe at the end. This
    // means the parser does zero allocations until validation
    // succeeds — easier to reason about cleanup on errors.
    var name_val: ?[]const u8 = null;
    var exec_val: ?[]const u8 = null;
    var comment_val: ?[]const u8 = null;

    var line_iter = std.mem.splitScalar(u8, contents, '\n');
    while (line_iter.next()) |raw_line| {
        // Strip trailing \r for files saved with CRLF line endings.
        var line = raw_line;
        if (line.len > 0 and line[line.len - 1] == '\r') {
            line = line[0 .. line.len - 1];
        }

        // Strip leading whitespace.
        var start: usize = 0;
        while (start < line.len and (line[start] == ' ' or line[start] == '\t')) {
            start += 1;
        }
        const trimmed = line[start..];

        if (trimmed.len == 0) continue; // blank line
        if (trimmed[0] == '#') continue; // comment

        // Section header?
        if (trimmed[0] == '[') {
            // Find matching `]`. ADR 0004 grammar: header ::= '[' section_name ']' ws* EOL
            const end = std.mem.indexOfScalar(u8, trimmed, ']') orelse {
                // Malformed header; skip the line per the tolerant
                // discovery rules.
                continue;
            };
            const section_name = trimmed[1..end];
            if (std.mem.eql(u8, section_name, "PGSD Session")) {
                in_section = true;
                found_header = true;
            } else {
                in_section = false;
            }
            continue;
        }

        if (!in_section) continue;

        // Assignment line. key ws* '=' ws* value ws* EOL.
        const eq = std.mem.indexOfScalar(u8, trimmed, '=') orelse continue;

        // Key: from start of trimmed up to eq, stripped of trailing ws.
        var key_end = eq;
        while (key_end > 0 and (trimmed[key_end - 1] == ' ' or trimmed[key_end - 1] == '\t')) {
            key_end -= 1;
        }
        const key = trimmed[0..key_end];

        if (!isValidKey(key)) return ParseError.InvalidKey;

        // Value: from eq+1, stripped of leading ws on both sides,
        // trailing ws on both sides.
        var val_start = eq + 1;
        while (val_start < trimmed.len and
            (trimmed[val_start] == ' ' or trimmed[val_start] == '\t'))
        {
            val_start += 1;
        }
        var val_end = trimmed.len;
        while (val_end > val_start and
            (trimmed[val_end - 1] == ' ' or trimmed[val_end - 1] == '\t'))
        {
            val_end -= 1;
        }
        const value = trimmed[val_start..val_end];

        // Reject embedded NULs in values; would break execvp.
        for (value) |ch| {
            if (ch == 0) return ParseError.EmbeddedNul;
        }

        if (std.mem.eql(u8, key, "Name")) {
            name_val = value;
        } else if (std.mem.eql(u8, key, "Exec")) {
            exec_val = value;
        } else if (std.mem.eql(u8, key, "Comment")) {
            comment_val = value;
        }
        // Unknown keys are silently ignored per ADR 0004's forward
        // compat policy.
    }

    if (!found_header) return ParseError.NoPgsdSessionHeader;

    // Required-field check.
    if (name_val == null) return ParseError.MissingName;
    if (exec_val == null) return ParseError.MissingExec;

    // Length checks.
    const name = name_val.?;
    const exec = exec_val.?;
    if (name.len == 0) return ParseError.EmptyName;
    if (exec.len == 0) return ParseError.EmptyExec;
    if (name.len > NAME_MAX) return ParseError.NameTooLong;
    if (exec.len > EXEC_MAX) return ParseError.ExecTooLong;
    if (comment_val) |cm| {
        if (cm.len > COMMENT_MAX) return ParseError.CommentTooLong;
    }

    // All validation passed; allocate owned copies.
    const id_dup = try allocator.dupe(u8, id);
    errdefer allocator.free(id_dup);
    const name_dup = try allocator.dupe(u8, name);
    errdefer allocator.free(name_dup);
    const exec_dup = try allocator.dupe(u8, exec);
    errdefer allocator.free(exec_dup);
    var comment_dup: ?[]u8 = null;
    if (comment_val) |cm| {
        comment_dup = try allocator.dupe(u8, cm);
    }

    return SessionFile{
        .id = id_dup,
        .name = name_dup,
        .exec = exec_dup,
        .comment = comment_dup,
    };
}

// =============================================================================
// File-based lookup
// =============================================================================
//
// Open <dir>/<id>.session, read it, parse it. Returns null if the
// file is absent. Returns a ParseError if the file exists but is
// malformed.

pub const LookupError = ParseError || error{
    FileTooLarge,
    IoError,
    InvalidSessionId,
};

pub fn lookupById(
    allocator: std.mem.Allocator,
    id: []const u8,
) LookupError!?SessionFile {
    return lookupByIdFrom(allocator, DEFAULT_SESSIONS_DIR, id);
}

pub fn lookupByIdFrom(
    allocator: std.mem.Allocator,
    dir: []const u8,
    id: []const u8,
) LookupError!?SessionFile {
    if (!isValidSessionId(id)) return LookupError.InvalidSessionId;

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(
        &path_buf,
        "{s}/{s}{s}",
        .{ dir, id, SESSION_EXT },
    ) catch return LookupError.InvalidSessionId;

    const file = std.fs.cwd().openFile(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return LookupError.IoError,
    };
    defer file.close();

    const stat = file.stat() catch return LookupError.IoError;
    if (stat.size > FILE_MAX) return LookupError.FileTooLarge;

    const contents = file.readToEndAlloc(allocator, FILE_MAX) catch
        return LookupError.IoError;
    defer allocator.free(contents);

    return try parseSessionFile(allocator, id, contents);
}

// =============================================================================
// Directory enumeration
// =============================================================================
//
// ADR 0004 §Discovery rules implemented end to end. Skips entries
// whose filename doesn't match the id regex (rather than warning,
// because non-.session files in the directory are fine). Warns and
// skips on parse failures of files whose names DO match the regex.

pub fn enumerate(allocator: std.mem.Allocator) !EnumerateResult {
    return enumerateFrom(allocator, DEFAULT_SESSIONS_DIR);
}

pub fn enumerateFrom(
    allocator: std.mem.Allocator,
    dir_path: []const u8,
) !EnumerateResult {
    var result = EnumerateResult{};
    errdefer result.deinit(allocator);

    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch |err| switch (err) {
        // Empty directory or missing directory is not a hard error;
        // just yields an empty result. The operator may not have
        // installed any .session files yet.
        error.FileNotFound => return result,
        else => return err,
    };
    defer dir.close();

    // Collect candidate filenames first, sort, then parse in order.
    // This means a single failing parse can't disrupt enumeration of
    // alphabetically later entries.
    var candidates = std.ArrayListUnmanaged([]u8){};
    defer {
        for (candidates.items) |s| allocator.free(s);
        candidates.deinit(allocator);
    }

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .file and entry.kind != .sym_link) continue;
        if (!std.mem.endsWith(u8, entry.name, SESSION_EXT)) continue;
        const id = entry.name[0 .. entry.name.len - SESSION_EXT.len];
        if (!isValidSessionId(id)) continue;
        const name_copy = try allocator.dupe(u8, entry.name);
        try candidates.append(allocator, name_copy);
    }

    std.mem.sort([]u8, candidates.items, {}, struct {
        fn lt(_: void, a: []u8, b: []u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);

    // Parse each candidate. Errors record a warning and continue.
    for (candidates.items) |filename| {
        const id = filename[0 .. filename.len - SESSION_EXT.len];

        const session_or_err = lookupByIdFrom(allocator, dir_path, id);
        if (session_or_err) |maybe_session| {
            if (maybe_session) |session| {
                try result.sessions.append(allocator, session);
            } else {
                // File vanished between iter and lookup. Warn.
                try appendWarning(allocator, &result, filename, "file disappeared during enumeration");
            }
        } else |err| {
            const reason = formatParseError(err);
            try appendWarning(allocator, &result, filename, reason);
        }
    }

    return result;
}

fn appendWarning(
    allocator: std.mem.Allocator,
    result: *EnumerateResult,
    filename: []const u8,
    reason: []const u8,
) !void {
    const filename_dup = try allocator.dupe(u8, filename);
    errdefer allocator.free(filename_dup);
    const reason_dup = try allocator.dupe(u8, reason);
    errdefer allocator.free(reason_dup);
    try result.warnings.append(allocator, .{
        .filename = filename_dup,
        .reason = reason_dup,
    });
}

fn formatParseError(err: anyerror) []const u8 {
    return switch (err) {
        ParseError.NoPgsdSessionHeader => "missing [PGSD Session] section",
        ParseError.MissingName => "missing required Name field",
        ParseError.MissingExec => "missing required Exec field",
        ParseError.EmptyName => "Name value is empty",
        ParseError.EmptyExec => "Exec value is empty",
        ParseError.NameTooLong => "Name exceeds 256 bytes",
        ParseError.ExecTooLong => "Exec exceeds 4096 bytes",
        ParseError.CommentTooLong => "Comment exceeds 512 bytes",
        ParseError.InvalidKey => "invalid key format (must match PascalCase ASCII)",
        ParseError.EmbeddedNul => "value contains embedded NUL byte",
        ParseError.OutOfMemory => "out of memory",
        LookupError.FileTooLarge => "file exceeds 64 KiB",
        LookupError.IoError => "I/O error reading file",
        LookupError.InvalidSessionId => "invalid session id",
        else => "unknown parse error",
    };
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "isValidSessionId accepts ADR 0004 examples" {
    try testing.expect(isValidSessionId("default"));
    try testing.expect(isValidSessionId("kiosk"));
    try testing.expect(isValidSessionId("new-session"));
    try testing.expect(isValidSessionId("my_session_1"));
    try testing.expect(isValidSessionId("a"));
}

test "isValidSessionId rejects bad ids" {
    try testing.expect(!isValidSessionId(""));
    try testing.expect(!isValidSessionId("Default")); // uppercase
    try testing.expect(!isValidSessionId("1session")); // starts with digit
    try testing.expect(!isValidSessionId("-session")); // starts with hyphen
    try testing.expect(!isValidSessionId("session.")); // dot
    try testing.expect(!isValidSessionId("session name")); // space
    try testing.expect(!isValidSessionId("../etc")); // path traversal
    try testing.expect(!isValidSessionId("/etc/passwd"));
}

test "isValidKey accepts ADR 0004 keys" {
    try testing.expect(isValidKey("Name"));
    try testing.expect(isValidKey("Exec"));
    try testing.expect(isValidKey("Comment"));
    try testing.expect(isValidKey("X9"));
}

test "isValidKey rejects bad keys" {
    try testing.expect(!isValidKey(""));
    try testing.expect(!isValidKey("name")); // lowercase first
    try testing.expect(!isValidKey("9Name")); // digit first
    try testing.expect(!isValidKey("Name-Other")); // hyphen
    try testing.expect(!isValidKey("Name[de]")); // FreeDesktop locale syntax
}

test "parseSessionFile happy path" {
    const sample =
        \\# default.session
        \\[PGSD Session]
        \\Name=Default UTF Session
        \\Exec=exec semadraw-term --fullscreen --scale 3
        \\Comment=PGSD's default session
        \\
    ;
    var session = try parseSessionFile(testing.allocator, "default", sample);
    defer session.deinit(testing.allocator);
    try testing.expectEqualStrings("default", session.id);
    try testing.expectEqualStrings("Default UTF Session", session.name);
    try testing.expectEqualStrings("exec semadraw-term --fullscreen --scale 3", session.exec);
    try testing.expectEqualStrings("PGSD's default session", session.comment.?);
}

test "parseSessionFile Comment is optional" {
    const sample =
        \\[PGSD Session]
        \\Name=Kiosk Mode
        \\Exec=exec semadraw-term --fullscreen --scale 2 --no-shell
        \\
    ;
    var session = try parseSessionFile(testing.allocator, "kiosk", sample);
    defer session.deinit(testing.allocator);
    try testing.expectEqualStrings("kiosk", session.id);
    try testing.expectEqualStrings("Kiosk Mode", session.name);
    try testing.expect(session.comment == null);
}

test "parseSessionFile tolerates CRLF and leading whitespace" {
    const sample = "[PGSD Session]\r\n  Name=My Name\r\n\tExec=foo bar\r\n";
    var session = try parseSessionFile(testing.allocator, "test", sample);
    defer session.deinit(testing.allocator);
    try testing.expectEqualStrings("My Name", session.name);
    try testing.expectEqualStrings("foo bar", session.exec);
}

test "parseSessionFile ignores unknown sections" {
    const sample =
        \\[Some Other Section]
        \\Name=Should be ignored
        \\Exec=ignored
        \\[PGSD Session]
        \\Name=Real Session
        \\Exec=real command
        \\[Another Section]
        \\Name=Also ignored
        \\
    ;
    var session = try parseSessionFile(testing.allocator, "test", sample);
    defer session.deinit(testing.allocator);
    try testing.expectEqualStrings("Real Session", session.name);
    try testing.expectEqualStrings("real command", session.exec);
}

test "parseSessionFile ignores unknown keys for forward compat" {
    const sample =
        \\[PGSD Session]
        \\Name=Forward Compat
        \\Exec=cmd
        \\FutureKey=v2 hotness
        \\AnotherFuture=more
        \\
    ;
    var session = try parseSessionFile(testing.allocator, "test", sample);
    defer session.deinit(testing.allocator);
    try testing.expectEqualStrings("Forward Compat", session.name);
}

test "parseSessionFile rejects missing PGSD Session header" {
    const sample =
        \\Name=Headerless
        \\Exec=cmd
        \\
    ;
    try testing.expectError(
        ParseError.NoPgsdSessionHeader,
        parseSessionFile(testing.allocator, "test", sample),
    );
}

test "parseSessionFile rejects missing Name" {
    const sample =
        \\[PGSD Session]
        \\Exec=cmd
        \\
    ;
    try testing.expectError(
        ParseError.MissingName,
        parseSessionFile(testing.allocator, "test", sample),
    );
}

test "parseSessionFile rejects missing Exec" {
    const sample =
        \\[PGSD Session]
        \\Name=No Exec
        \\
    ;
    try testing.expectError(
        ParseError.MissingExec,
        parseSessionFile(testing.allocator, "test", sample),
    );
}

test "parseSessionFile rejects empty Name and Exec" {
    const sample_empty_name =
        \\[PGSD Session]
        \\Name=
        \\Exec=cmd
        \\
    ;
    try testing.expectError(
        ParseError.EmptyName,
        parseSessionFile(testing.allocator, "test", sample_empty_name),
    );

    const sample_empty_exec =
        \\[PGSD Session]
        \\Name=Foo
        \\Exec=
        \\
    ;
    try testing.expectError(
        ParseError.EmptyExec,
        parseSessionFile(testing.allocator, "test", sample_empty_exec),
    );
}

test "parseSessionFile rejects bad key syntax" {
    const sample =
        \\[PGSD Session]
        \\name=lowercase first
        \\Exec=cmd
        \\
    ;
    try testing.expectError(
        ParseError.InvalidKey,
        parseSessionFile(testing.allocator, "test", sample),
    );
}

test "parseSessionFile preserves # inside values per ADR 0004" {
    // ADR 0004 §Notes: "A # inside a value is part of the value."
    const sample =
        \\[PGSD Session]
        \\Name=Tagged
        \\Exec=exec foo --url=https://example.org/page#fragment
        \\
    ;
    var session = try parseSessionFile(testing.allocator, "test", sample);
    defer session.deinit(testing.allocator);
    try testing.expectEqualStrings(
        "exec foo --url=https://example.org/page#fragment",
        session.exec,
    );
}

test "parseSessionFile strips whitespace around = per grammar" {
    // Use a regular string (not a `\\` multiline) because Zig's
    // multi-line string literals reject literal tab characters.
    // `\t` escapes are only available in regular strings.
    const sample = "[PGSD Session]\n" ++
        "Name   =   Padded Spaces\n" ++
        "Exec\t=\ttab padded\n";
    var session = try parseSessionFile(testing.allocator, "test", sample);
    defer session.deinit(testing.allocator);
    try testing.expectEqualStrings("Padded Spaces", session.name);
    try testing.expectEqualStrings("tab padded", session.exec);
}

test "enumerate on empty directory" {
    // Use a real tmp dir created via fs.cwd().makeDir.
    const tmp_name = "pgsd_s4_test_empty";
    std.fs.cwd().makeDir(tmp_name) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return e,
    };
    defer std.fs.cwd().deleteTree(tmp_name) catch {};

    var result = try enumerateFrom(testing.allocator, tmp_name);
    defer result.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), result.sessions.items.len);
    try testing.expectEqual(@as(usize, 0), result.warnings.items.len);
}

test "enumerate finds and sorts valid sessions" {
    const tmp_name = "pgsd_s4_test_valid";
    std.fs.cwd().makeDir(tmp_name) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return e,
    };
    defer std.fs.cwd().deleteTree(tmp_name) catch {};

    // Write three valid sessions out of alphabetical order.
    try writeTestSession(tmp_name, "kiosk.session",
        \\[PGSD Session]
        \\Name=Kiosk Mode
        \\Exec=kiosk-cmd
        \\
    );
    try writeTestSession(tmp_name, "default.session",
        \\[PGSD Session]
        \\Name=Default UTF Session
        \\Exec=default-cmd
        \\Comment=PGSD default
        \\
    );
    try writeTestSession(tmp_name, "alpha.session",
        \\[PGSD Session]
        \\Name=Alpha Test
        \\Exec=alpha-cmd
        \\
    );

    var result = try enumerateFrom(testing.allocator, tmp_name);
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 3), result.sessions.items.len);
    try testing.expectEqual(@as(usize, 0), result.warnings.items.len);

    // Sort order: alpha, default, kiosk.
    try testing.expectEqualStrings("alpha", result.sessions.items[0].id);
    try testing.expectEqualStrings("default", result.sessions.items[1].id);
    try testing.expectEqualStrings("kiosk", result.sessions.items[2].id);
}

test "enumerate skips malformed files with warnings" {
    const tmp_name = "pgsd_s4_test_malformed";
    std.fs.cwd().makeDir(tmp_name) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return e,
    };
    defer std.fs.cwd().deleteTree(tmp_name) catch {};

    try writeTestSession(tmp_name, "good.session",
        \\[PGSD Session]
        \\Name=Good One
        \\Exec=ok
        \\
    );
    try writeTestSession(tmp_name, "broken.session",
        \\[Wrong Section]
        \\Name=Bad
        \\
    );
    try writeTestSession(tmp_name, "missing-exec.session",
        \\[PGSD Session]
        \\Name=Missing Exec
        \\
    );

    var result = try enumerateFrom(testing.allocator, tmp_name);
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), result.sessions.items.len);
    try testing.expectEqualStrings("good", result.sessions.items[0].id);
    try testing.expectEqual(@as(usize, 2), result.warnings.items.len);
}

test "enumerate ignores files not matching session-id regex" {
    const tmp_name = "pgsd_s4_test_filter";
    std.fs.cwd().makeDir(tmp_name) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return e,
    };
    defer std.fs.cwd().deleteTree(tmp_name) catch {};

    // Should NOT be enumerated:
    try writeTestSession(tmp_name, "Capital.session", "[PGSD Session]\nName=x\nExec=x\n");
    try writeTestSession(tmp_name, ".hidden.session", "[PGSD Session]\nName=x\nExec=x\n");
    try writeTestSession(tmp_name, "1numeric.session", "[PGSD Session]\nName=x\nExec=x\n");
    try writeTestSession(tmp_name, "noext", "[PGSD Session]\nName=x\nExec=x\n");
    try writeTestSession(tmp_name, "README", "not a session file");

    // Should be enumerated:
    try writeTestSession(tmp_name, "valid.session",
        \\[PGSD Session]
        \\Name=Valid
        \\Exec=cmd
        \\
    );

    var result = try enumerateFrom(testing.allocator, tmp_name);
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), result.sessions.items.len);
    try testing.expectEqualStrings("valid", result.sessions.items[0].id);
    try testing.expectEqual(@as(usize, 0), result.warnings.items.len);
}

test "lookupByIdFrom returns null when file is absent" {
    const tmp_name = "pgsd_s4_test_absent";
    std.fs.cwd().makeDir(tmp_name) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return e,
    };
    defer std.fs.cwd().deleteTree(tmp_name) catch {};

    const result = try lookupByIdFrom(testing.allocator, tmp_name, "does-not-exist");
    try testing.expect(result == null);
}

test "lookupByIdFrom rejects invalid session ids" {
    try testing.expectError(
        LookupError.InvalidSessionId,
        lookupByIdFrom(testing.allocator, "/tmp", "Invalid"),
    );
}

// Helper for tests.
fn writeTestSession(dir: []const u8, filename: []const u8, contents: []const u8) !void {
    var d = try std.fs.cwd().openDir(dir, .{});
    defer d.close();
    var f = try d.createFile(filename, .{ .truncate = true });
    defer f.close();
    try f.writeAll(contents);
}
