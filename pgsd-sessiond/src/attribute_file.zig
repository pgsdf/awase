// pgsd-sessiond/src/attribute_file.zig
//
// Parses /etc/utf/users/<username>.conf per ADR 0003.
//
// Format reminder (see docs/adr/0003-attribute-file-format.md for the
// canonical grammar):
//
//   - One key=value assignment per line. Keys are lowercase ASCII
//     letters, digits, underscores. Values are UTF-8.
//   - `#` introduces a comment to end of line (no quoting in v1).
//   - Whitespace around `=` is stripped; whitespace inside values
//     preserved.
//   - Unknown keys: warn-and-skip.
//   - Invalid lines: warn-and-skip.
//   - File not found: silently treated as empty (defaults apply).
//   - Other I/O errors: warning-logged, defaults apply.
//   - Duplicate keys: last wins, prior occurrence warned.
//   - File size limit: 64 KiB (DOS defence).
//   - v1 fields: display_name, default_session, avatar_path (reserved),
//     age_bracket, capabilities.

const std = @import("std");
const compat = @import("compat");

// =============================================================================
// Field types
// =============================================================================

pub const AgeBracket = enum {
    unspecified,
    under_13,
    @"13_15",
    @"16_17",
    adult,

    pub fn fromString(s: []const u8) ?AgeBracket {
        // ADR 0003 specifies the strings with hyphens; Zig identifier syntax
        // forces underscores in enum members, so we map at parse time.
        if (std.mem.eql(u8, s, "unspecified")) return .unspecified;
        if (std.mem.eql(u8, s, "under-13")) return .under_13;
        if (std.mem.eql(u8, s, "13-15")) return .@"13_15";
        if (std.mem.eql(u8, s, "16-17")) return .@"16_17";
        if (std.mem.eql(u8, s, "adult")) return .adult;
        return null;
    }

    pub fn toString(self: AgeBracket) []const u8 {
        return switch (self) {
            .unspecified => "unspecified",
            .under_13 => "under-13",
            .@"13_15" => "13-15",
            .@"16_17" => "16-17",
            .adult => "adult",
        };
    }
};

// =============================================================================
// Parsed attribute set
// =============================================================================

pub const Attributes = struct {
    // All string fields are heap-allocated when set; deinit frees them.
    display_name: ?[]const u8 = null,
    default_session: ?[]const u8 = null,
    avatar_path: ?[]const u8 = null,
    age_bracket: AgeBracket = .unspecified,
    capabilities: std.ArrayListUnmanaged([]const u8) = .empty,

    // Warnings accumulated during parse. Each entry is a heap-allocated
    // human-readable message including line number where applicable.
    warnings: std.ArrayListUnmanaged([]const u8) = .empty,

    pub fn deinit(self: *Attributes, allocator: std.mem.Allocator) void {
        if (self.display_name) |s| allocator.free(s);
        if (self.default_session) |s| allocator.free(s);
        if (self.avatar_path) |s| allocator.free(s);
        for (self.capabilities.items) |c| allocator.free(c);
        self.capabilities.deinit(allocator);
        for (self.warnings.items) |w| allocator.free(w);
        self.warnings.deinit(allocator);
    }
};

// =============================================================================
// Lookup path construction
// =============================================================================
//
// ADR 0003: username must match [a-z_][a-z0-9_-]* with length 1..32.
// This is the same regex pw(8) uses on FreeBSD (MAXLOGNAME = 33 including
// the null terminator, so 32 usable bytes).
//
// Even though getpwent returns kernel-validated usernames, we re-validate
// here as a defence-in-depth measure: anything that constructs a path
// from a string must validate that string against a known-safe regex,
// regardless of source.

pub fn isValidUsername(name: []const u8) bool {
    if (name.len == 0 or name.len > 32) return false;
    const first = name[0];
    if (!((first >= 'a' and first <= 'z') or first == '_')) return false;
    for (name[1..]) |ch| {
        const ok = (ch >= 'a' and ch <= 'z') or
            (ch >= '0' and ch <= '9') or
            ch == '_' or ch == '-';
        if (!ok) return false;
    }
    return true;
}

// =============================================================================
// Load and parse
// =============================================================================
//
// Public entry point. Returns an Attributes with defaults filled in for
// any field not present in the file. File-not-found returns a default
// Attributes with no warnings. Other I/O errors return a default
// Attributes with a single warning describing the failure.

pub fn loadForUser(
    allocator: std.mem.Allocator,
    username: []const u8,
) !Attributes {
    return loadFromDir(allocator, "/etc/utf/users", username);
}

// Variant that takes the directory path explicitly. Useful for tests
// that don't want to require root or write to /etc.
pub fn loadFromDir(
    allocator: std.mem.Allocator,
    dir: []const u8,
    username: []const u8,
) !Attributes {
    var attrs = Attributes{};
    errdefer attrs.deinit(allocator);

    if (!isValidUsername(username)) {
        try addWarning(allocator, &attrs, "invalid username; refusing to look up attribute file");
        return attrs;
    }

    // Build the file path: <dir>/<username>.conf
    var path_buf: [PATH_MAX]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}.conf", .{ dir, username }) catch {
        try addWarning(allocator, &attrs, "path construction failed (username too long?)");
        return attrs;
    };

    // Read through compat.fs: 0.16 routes the filesystem under std.Io. The Io
    // context is owned locally (ADR shared 0001 Decision 2); this function
    // already holds the allocator it needs to construct one. The oversize file
    // surfaces as StreamTooLong from the bounded read, preserving the prior
    // FileTooBig "ignore entirely" behaviour without a separate stat.
    var io_ctx = compat.io.open(allocator) catch {
        try addWarning(allocator, &attrs, "could not initialise I/O context");
        return attrs;
    };
    defer io_ctx.deinit();

    var file = compat.fs.cwd(io_ctx.io()).openFile(path) catch |err| switch (err) {
        error.FileNotFound => return attrs, // silent: ADR 0003 §Read strategy
        else => {
            const msg = std.fmt.allocPrint(
                allocator,
                "could not read attribute file: {s}",
                .{@errorName(err)},
            ) catch return attrs;
            try attrs.warnings.append(allocator, msg);
            return attrs;
        },
    };
    defer file.close();

    const data = file.readToEndAlloc(allocator, MAX_FILE_SIZE) catch |err| switch (err) {
        error.StreamTooLong => {
            try addWarning(allocator, &attrs, "attribute file exceeds 64 KiB; ignoring entirely");
            return attrs;
        },
        else => {
            const msg = std.fmt.allocPrint(
                allocator,
                "could not read attribute file: {s}",
                .{@errorName(err)},
            ) catch return attrs;
            try attrs.warnings.append(allocator, msg);
            return attrs;
        },
    };
    defer allocator.free(data);

    try parseInto(allocator, &attrs, data);
    return attrs;
}

const PATH_MAX = 1024; // sufficient for /etc/utf/users/<32-char>.conf
const MAX_FILE_SIZE = 64 * 1024;

// =============================================================================
// Inner parser
// =============================================================================

fn parseInto(
    allocator: std.mem.Allocator,
    attrs: *Attributes,
    data: []const u8,
) !void {
    var line_no: u32 = 0;
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |raw_line| {
        line_no += 1;

        // Trim CR (for CRLF tolerance), then leading/trailing whitespace.
        const no_cr = std.mem.trimEnd(u8, raw_line, "\r");
        const line = std.mem.trim(u8, no_cr, " \t");

        if (line.len == 0) continue;
        if (line[0] == '#') continue;

        // Find '=' for the assignment split.
        const eq_idx = std.mem.indexOfScalar(u8, line, '=') orelse {
            try addWarningFmt(
                allocator,
                attrs,
                "line {d}: not a key=value assignment; skipped",
                .{line_no},
            );
            continue;
        };

        const key_raw = line[0..eq_idx];
        const after_eq = line[eq_idx + 1 ..];

        const key = std.mem.trim(u8, key_raw, " \t");
        if (!isValidKey(key)) {
            try addWarningFmt(
                allocator,
                attrs,
                "line {d}: invalid key syntax; skipped",
                .{line_no},
            );
            continue;
        }

        // Value handling: strip inline comment (anything after '#'),
        // then trim whitespace. ADR 0003 says `#` always starts a comment
        // since v1 has no quoting; this matches the per-user attribute
        // file (NOT the .session file, which has different rules).
        const value_raw = if (std.mem.indexOfScalar(u8, after_eq, '#')) |hash_idx|
            after_eq[0..hash_idx]
        else
            after_eq;
        const value = std.mem.trim(u8, value_raw, " \t");

        try applyField(allocator, attrs, key, value, line_no);
    }
}

fn isValidKey(key: []const u8) bool {
    if (key.len == 0) return false;
    const first = key[0];
    if (!(first >= 'a' and first <= 'z')) return false;
    for (key[1..]) |ch| {
        const ok = (ch >= 'a' and ch <= 'z') or
            (ch >= '0' and ch <= '9') or
            ch == '_';
        if (!ok) return false;
    }
    return true;
}

fn applyField(
    allocator: std.mem.Allocator,
    attrs: *Attributes,
    key: []const u8,
    value: []const u8,
    line_no: u32,
) !void {
    if (std.mem.eql(u8, key, "display_name")) {
        if (value.len == 0) return; // empty value = field absent
        if (value.len > 256) {
            try addWarningFmt(allocator, attrs, "line {d}: display_name exceeds 256 bytes; truncating", .{line_no});
        }
        if (!std.unicode.utf8ValidateSlice(value)) {
            try addWarningFmt(allocator, attrs, "line {d}: display_name is not valid UTF-8; skipping", .{line_no});
            return;
        }
        try replaceString(allocator, attrs, &attrs.display_name, value, "display_name", line_no);
    } else if (std.mem.eql(u8, key, "default_session")) {
        if (value.len == 0) return;
        if (value.len > 64) {
            try addWarningFmt(allocator, attrs, "line {d}: default_session exceeds 64 bytes; skipping", .{line_no});
            return;
        }
        if (!isValidSessionId(value)) {
            try addWarningFmt(allocator, attrs, "line {d}: default_session contains invalid characters; skipping", .{line_no});
            return;
        }
        try replaceString(allocator, attrs, &attrs.default_session, value, "default_session", line_no);
    } else if (std.mem.eql(u8, key, "avatar_path")) {
        // Reserved in v1: stored but not used.
        if (value.len == 0) return;
        if (value.len > PATH_MAX) {
            try addWarningFmt(allocator, attrs, "line {d}: avatar_path exceeds PATH_MAX; skipping", .{line_no});
            return;
        }
        try replaceString(allocator, attrs, &attrs.avatar_path, value, "avatar_path", line_no);
    } else if (std.mem.eql(u8, key, "age_bracket")) {
        const bracket = AgeBracket.fromString(value) orelse {
            try addWarningFmt(allocator, attrs, "line {d}: unknown age_bracket value '{s}'; using default", .{ line_no, value });
            return;
        };
        attrs.age_bracket = bracket;
    } else if (std.mem.eql(u8, key, "capabilities")) {
        try parseCapabilities(allocator, attrs, value, line_no);
    } else {
        try addWarningFmt(allocator, attrs, "line {d}: unknown key '{s}'; ignored", .{ line_no, key });
    }
}

// Helper: free prior value (if duplicate), allocate new copy. Adds a
// duplicate-key warning when overwriting.
fn replaceString(
    allocator: std.mem.Allocator,
    attrs: *Attributes,
    field: *?[]const u8,
    value: []const u8,
    field_name: []const u8,
    line_no: u32,
) !void {
    if (field.*) |old| {
        allocator.free(old);
        try addWarningFmt(allocator, attrs, "line {d}: duplicate key '{s}'; previous value overridden", .{ line_no, field_name });
    }
    field.* = try allocator.dupe(u8, value);
}

fn isValidSessionId(s: []const u8) bool {
    if (s.len == 0) return false;
    const first = s[0];
    if (!(first >= 'a' and first <= 'z')) return false;
    for (s[1..]) |ch| {
        const ok = (ch >= 'a' and ch <= 'z') or
            (ch >= '0' and ch <= '9') or
            ch == '_' or ch == '-';
        if (!ok) return false;
    }
    return true;
}

fn isValidCapability(s: []const u8) bool {
    return isValidSessionId(s); // same character class
}

fn parseCapabilities(
    allocator: std.mem.Allocator,
    attrs: *Attributes,
    value: []const u8,
    line_no: u32,
) !void {
    if (value.len > 1024) {
        try addWarningFmt(allocator, attrs, "line {d}: capabilities exceeds 1024 bytes; skipping", .{line_no});
        return;
    }

    // If we've seen capabilities before, the last-wins rule means we
    // clear the previous list. ADR 0003 specifies last-wins behaviour.
    if (attrs.capabilities.items.len > 0) {
        for (attrs.capabilities.items) |c| allocator.free(c);
        attrs.capabilities.clearRetainingCapacity();
        try addWarningFmt(allocator, attrs, "line {d}: duplicate key 'capabilities'; previous list overridden", .{line_no});
    }

    var it = std.mem.splitScalar(u8, value, ',');
    while (it.next()) |raw_cap| {
        const cap = std.mem.trim(u8, raw_cap, " \t");
        if (cap.len == 0) continue; // skip empty entries silently per ADR 0003
        if (!isValidCapability(cap)) {
            try addWarningFmt(allocator, attrs, "line {d}: capability '{s}' has invalid syntax; skipping", .{ line_no, cap });
            continue;
        }
        const copy = try allocator.dupe(u8, cap);
        try attrs.capabilities.append(allocator, copy);
    }
}

fn addWarning(
    allocator: std.mem.Allocator,
    attrs: *Attributes,
    msg: []const u8,
) !void {
    const copy = try allocator.dupe(u8, msg);
    try attrs.warnings.append(allocator, copy);
}

fn addWarningFmt(
    allocator: std.mem.Allocator,
    attrs: *Attributes,
    comptime fmt: []const u8,
    args: anytype,
) !void {
    const msg = try std.fmt.allocPrint(allocator, fmt, args);
    try attrs.warnings.append(allocator, msg);
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "isValidUsername accepts standard names" {
    try testing.expect(isValidUsername("vic"));
    try testing.expect(isValidUsername("_pgsd_sessiond"));
    try testing.expect(isValidUsername("user1"));
    try testing.expect(isValidUsername("a-b_c"));
}

test "isValidUsername rejects path traversal" {
    try testing.expect(!isValidUsername(".."));
    try testing.expect(!isValidUsername("../passwd"));
    try testing.expect(!isValidUsername("/etc/passwd"));
    try testing.expect(!isValidUsername(""));
    try testing.expect(!isValidUsername("ABC")); // uppercase rejected
    try testing.expect(!isValidUsername("1abc")); // can't start with digit
    try testing.expect(!isValidUsername("a" ** 33)); // too long
}

test "AgeBracket round-trips" {
    try testing.expectEqual(AgeBracket.unspecified, AgeBracket.fromString("unspecified").?);
    try testing.expectEqual(AgeBracket.under_13, AgeBracket.fromString("under-13").?);
    try testing.expectEqual(AgeBracket.@"13_15", AgeBracket.fromString("13-15").?);
    try testing.expectEqual(AgeBracket.adult, AgeBracket.fromString("adult").?);
    try testing.expect(AgeBracket.fromString("child") == null);
    try testing.expect(AgeBracket.fromString("") == null);

    try testing.expectEqualStrings("under-13", AgeBracket.under_13.toString());
    try testing.expectEqualStrings("adult", AgeBracket.adult.toString());
}

test "parser handles a complete valid file" {
    const data =
        \\# Catherine Smith, primary workstation user.
        \\display_name = Catherine Smith
        \\default_session = nde
        \\age_bracket = adult
        \\capabilities = can-shutdown, can-add-users
        \\
    ;
    var attrs = Attributes{};
    defer attrs.deinit(testing.allocator);

    try parseInto(testing.allocator, &attrs, data);

    try testing.expectEqualStrings("Catherine Smith", attrs.display_name.?);
    try testing.expectEqualStrings("nde", attrs.default_session.?);
    try testing.expectEqual(AgeBracket.adult, attrs.age_bracket);
    try testing.expectEqual(@as(usize, 2), attrs.capabilities.items.len);
    try testing.expectEqualStrings("can-shutdown", attrs.capabilities.items[0]);
    try testing.expectEqualStrings("can-add-users", attrs.capabilities.items[1]);
    try testing.expectEqual(@as(usize, 0), attrs.warnings.items.len);
}

test "parser skips blank and comment lines silently" {
    const data =
        \\
        \\# leading comment
        \\
        \\display_name = Vic
        \\# middle comment
        \\age_bracket = adult
        \\
    ;
    var attrs = Attributes{};
    defer attrs.deinit(testing.allocator);

    try parseInto(testing.allocator, &attrs, data);

    try testing.expectEqualStrings("Vic", attrs.display_name.?);
    try testing.expectEqual(AgeBracket.adult, attrs.age_bracket);
    try testing.expectEqual(@as(usize, 0), attrs.warnings.items.len);
}

test "parser strips inline comments from values" {
    const data = "display_name = Vic Thacker  # the operator\n";
    var attrs = Attributes{};
    defer attrs.deinit(testing.allocator);

    try parseInto(testing.allocator, &attrs, data);

    try testing.expectEqualStrings("Vic Thacker", attrs.display_name.?);
}

test "parser preserves internal whitespace" {
    const data = "display_name = Catherine   Smith\n";
    var attrs = Attributes{};
    defer attrs.deinit(testing.allocator);

    try parseInto(testing.allocator, &attrs, data);

    try testing.expectEqualStrings("Catherine   Smith", attrs.display_name.?);
}

test "parser warns on unknown key but continues" {
    const data =
        \\display_name = Vic
        \\unknown_key = whatever
        \\age_bracket = adult
        \\
    ;
    var attrs = Attributes{};
    defer attrs.deinit(testing.allocator);

    try parseInto(testing.allocator, &attrs, data);

    try testing.expectEqualStrings("Vic", attrs.display_name.?);
    try testing.expectEqual(AgeBracket.adult, attrs.age_bracket);
    try testing.expectEqual(@as(usize, 1), attrs.warnings.items.len);
}

test "parser warns on invalid age_bracket and keeps default" {
    const data =
        \\display_name = Vic
        \\age_bracket = wizard
        \\
    ;
    var attrs = Attributes{};
    defer attrs.deinit(testing.allocator);

    try parseInto(testing.allocator, &attrs, data);

    try testing.expectEqualStrings("Vic", attrs.display_name.?);
    try testing.expectEqual(AgeBracket.unspecified, attrs.age_bracket);
    try testing.expectEqual(@as(usize, 1), attrs.warnings.items.len);
}

test "parser warns on malformed line and continues" {
    const data =
        \\display_name = Vic
        \\malformed line with no equals
        \\age_bracket = adult
        \\
    ;
    var attrs = Attributes{};
    defer attrs.deinit(testing.allocator);

    try parseInto(testing.allocator, &attrs, data);

    try testing.expectEqualStrings("Vic", attrs.display_name.?);
    try testing.expectEqual(AgeBracket.adult, attrs.age_bracket);
    try testing.expectEqual(@as(usize, 1), attrs.warnings.items.len);
}

test "parser handles duplicate key with last-wins and a warning" {
    const data =
        \\display_name = First
        \\display_name = Second
        \\
    ;
    var attrs = Attributes{};
    defer attrs.deinit(testing.allocator);

    try parseInto(testing.allocator, &attrs, data);

    try testing.expectEqualStrings("Second", attrs.display_name.?);
    try testing.expectEqual(@as(usize, 1), attrs.warnings.items.len);
}

test "parser handles empty file as defaults" {
    var attrs = Attributes{};
    defer attrs.deinit(testing.allocator);

    try parseInto(testing.allocator, &attrs, "");

    try testing.expect(attrs.display_name == null);
    try testing.expect(attrs.default_session == null);
    try testing.expectEqual(AgeBracket.unspecified, attrs.age_bracket);
    try testing.expectEqual(@as(usize, 0), attrs.capabilities.items.len);
}

test "parser handles capabilities with whitespace and empty entries" {
    const data = "capabilities = can-shutdown , , can-add-users,\n";
    var attrs = Attributes{};
    defer attrs.deinit(testing.allocator);

    try parseInto(testing.allocator, &attrs, data);

    try testing.expectEqual(@as(usize, 2), attrs.capabilities.items.len);
    try testing.expectEqualStrings("can-shutdown", attrs.capabilities.items[0]);
    try testing.expectEqualStrings("can-add-users", attrs.capabilities.items[1]);
    try testing.expectEqual(@as(usize, 0), attrs.warnings.items.len);
}

test "parser rejects invalid session_id in default_session" {
    const data = "default_session = NDE\n"; // uppercase rejected
    var attrs = Attributes{};
    defer attrs.deinit(testing.allocator);

    try parseInto(testing.allocator, &attrs, data);

    try testing.expect(attrs.default_session == null);
    try testing.expectEqual(@as(usize, 1), attrs.warnings.items.len);
}

test "parser tolerates CRLF line endings" {
    const data = "display_name = Vic\r\nage_bracket = adult\r\n";
    var attrs = Attributes{};
    defer attrs.deinit(testing.allocator);

    try parseInto(testing.allocator, &attrs, data);

    try testing.expectEqualStrings("Vic", attrs.display_name.?);
    try testing.expectEqual(AgeBracket.adult, attrs.age_bracket);
    try testing.expectEqual(@as(usize, 0), attrs.warnings.items.len);
}

test "loadFromDir returns defaults silently when file is absent" {
    // Use a directory that exists but won't have a .conf for "nobody"
    var attrs = try loadFromDir(testing.allocator, "/tmp", "nobody_nonexistent_user");
    defer attrs.deinit(testing.allocator);

    try testing.expect(attrs.display_name == null);
    try testing.expectEqual(@as(usize, 0), attrs.warnings.items.len);
}

test "loadFromDir refuses invalid username" {
    var attrs = try loadFromDir(testing.allocator, "/tmp", "../passwd");
    defer attrs.deinit(testing.allocator);

    try testing.expect(attrs.display_name == null);
    try testing.expectEqual(@as(usize, 1), attrs.warnings.items.len);
}
