// pgsd-sessiond/src/user_enum.zig
//
// Enumerates real (login-capable) users from /etc/master.passwd via
// getpwent(3), filtered by:
//
//   - UID > 1000 (system users excluded; matches ADR 0001's selection)
//   - pw_shell present in /etc/shells (consulted via getusershell(3))
//
// For each surviving user, the attribute file at
// /etc/utf/users/<name>.conf is read per ADR 0003.
//
// The result is an owned list of EnumeratedUser entries. The caller
// is responsible for calling deinit on the list.

const std = @import("std");
const attribute_file = @import("attribute_file.zig");

const c = @cImport({
    @cInclude("pwd.h");
    @cInclude("unistd.h");
});

pub const EnumeratedUser = struct {
    name: []const u8, // username (owned)
    uid: u32,
    gid: u32,
    home: []const u8, // pw_dir (owned)
    shell: []const u8, // pw_shell (owned)
    gecos: []const u8, // pw_gecos first comma-field (owned)
    attrs: attribute_file.Attributes,

    pub fn deinit(self: *EnumeratedUser, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.home);
        allocator.free(self.shell);
        allocator.free(self.gecos);
        self.attrs.deinit(allocator);
    }

    // Resolved display name: attribute file's display_name if set,
    // otherwise GECOS first comma-field if non-empty, otherwise username.
    // The returned slice is borrowed from self; valid until self is freed.
    pub fn displayName(self: *const EnumeratedUser) []const u8 {
        if (self.attrs.display_name) |s| return s;
        if (self.gecos.len > 0) return self.gecos;
        return self.name;
    }
};

pub const UserList = struct {
    users: std.ArrayListUnmanaged(EnumeratedUser) = .{},

    pub fn deinit(self: *UserList, allocator: std.mem.Allocator) void {
        for (self.users.items) |*u| u.deinit(allocator);
        self.users.deinit(allocator);
    }
};

// =============================================================================
// /etc/shells lookup via getusershell(3)
// =============================================================================

const ShellSet = struct {
    shells: std.ArrayListUnmanaged([]const u8) = .{},

    fn deinit(self: *ShellSet, allocator: std.mem.Allocator) void {
        for (self.shells.items) |s| allocator.free(s);
        self.shells.deinit(allocator);
    }

    fn contains(self: *const ShellSet, shell: []const u8) bool {
        for (self.shells.items) |s| {
            if (std.mem.eql(u8, s, shell)) return true;
        }
        return false;
    }
};

fn loadValidShells(allocator: std.mem.Allocator) !ShellSet {
    var set = ShellSet{};
    errdefer set.deinit(allocator);

    c.setusershell();
    defer c.endusershell();

    while (true) {
        const ptr = c.getusershell();
        if (ptr == null) break;
        const cstr: [*:0]const u8 = @ptrCast(ptr);
        const shell = std.mem.span(cstr);
        const copy = try allocator.dupe(u8, shell);
        try set.shells.append(allocator, copy);
    }
    return set;
}

// =============================================================================
// GECOS field extraction
// =============================================================================
//
// GECOS is comma-separated: "Full Name,Office,Phone,Other". Only the
// first field is the display name; subsequent fields are operator
// metadata (per FreeBSD convention). Empty GECOS or empty first field
// returns "".

fn extractGecosName(gecos_raw: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, gecos_raw, ',')) |idx| {
        return gecos_raw[0..idx];
    }
    return gecos_raw;
}

// =============================================================================
// Main enumeration
// =============================================================================
//
// MIN_UID matches ADR 0001's "UID > 1000" filter. UIDs 0-1000 are
// system accounts on FreeBSD by convention.

const MIN_UID: u32 = 1001;

pub fn enumerate(allocator: std.mem.Allocator) !UserList {
    var list = UserList{};
    errdefer list.deinit(allocator);

    var shells = try loadValidShells(allocator);
    defer shells.deinit(allocator);

    c.setpwent();
    defer c.endpwent();

    while (true) {
        const entry = c.getpwent();
        if (entry == null) break;
        const pw = entry.?;

        const uid: u32 = @intCast(pw.*.pw_uid);
        if (uid <= MIN_UID - 1) continue;

        const name_cstr: [*:0]const u8 = @ptrCast(pw.*.pw_name);
        const name = std.mem.span(name_cstr);
        if (!attribute_file.isValidUsername(name)) continue;

        const shell_cstr: [*:0]const u8 = @ptrCast(pw.*.pw_shell);
        const shell = std.mem.span(shell_cstr);
        if (!shells.contains(shell)) continue;

        const home_cstr: [*:0]const u8 = @ptrCast(pw.*.pw_dir);
        const home = std.mem.span(home_cstr);

        const gecos_cstr: [*:0]const u8 = @ptrCast(pw.*.pw_gecos);
        const gecos_raw = std.mem.span(gecos_cstr);
        const gecos = extractGecosName(gecos_raw);

        const gid: u32 = @intCast(pw.*.pw_gid);

        // Allocate copies of all strings (getpwent returns pointers into
        // a static buffer that gets reused on the next call).
        const name_copy = try allocator.dupe(u8, name);
        errdefer allocator.free(name_copy);
        const home_copy = try allocator.dupe(u8, home);
        errdefer allocator.free(home_copy);
        const shell_copy = try allocator.dupe(u8, shell);
        errdefer allocator.free(shell_copy);
        const gecos_copy = try allocator.dupe(u8, gecos);
        errdefer allocator.free(gecos_copy);

        // Read per-user attribute file (silent on FileNotFound).
        var attrs = try attribute_file.loadForUser(allocator, name);
        errdefer attrs.deinit(allocator);

        try list.users.append(allocator, EnumeratedUser{
            .name = name_copy,
            .uid = uid,
            .gid = gid,
            .home = home_copy,
            .shell = shell_copy,
            .gecos = gecos_copy,
            .attrs = attrs,
        });
    }

    return list;
}

// =============================================================================
// Single-user lookup (stage 3)
// =============================================================================
//
// Stage 3's --launch flow needs to resolve a username to a passwd entry
// to perform the privilege drop. The validations are the same as
// enumerate(): UID > 1000, shell in /etc/shells, valid username.
// Returns null if the user is not found or fails any validation.

pub fn lookupByName(
    allocator: std.mem.Allocator,
    name: []const u8,
) !?EnumeratedUser {
    if (!attribute_file.isValidUsername(name)) return null;

    // getpwnam takes a NUL-terminated C string.
    const name_z = try allocator.dupeZ(u8, name);
    defer allocator.free(name_z);

    const entry = c.getpwnam(name_z.ptr);
    if (entry == null) return null;
    const pw = entry.?;

    const uid: u32 = @intCast(pw.*.pw_uid);
    if (uid <= MIN_UID - 1) return null;

    const shell_cstr: [*:0]const u8 = @ptrCast(pw.*.pw_shell);
    const shell = std.mem.span(shell_cstr);

    var shells = try loadValidShells(allocator);
    defer shells.deinit(allocator);
    if (!shells.contains(shell)) return null;

    const name_cstr: [*:0]const u8 = @ptrCast(pw.*.pw_name);
    const pw_name = std.mem.span(name_cstr);

    const home_cstr: [*:0]const u8 = @ptrCast(pw.*.pw_dir);
    const home = std.mem.span(home_cstr);

    const gecos_cstr: [*:0]const u8 = @ptrCast(pw.*.pw_gecos);
    const gecos_raw = std.mem.span(gecos_cstr);
    const gecos = extractGecosName(gecos_raw);

    const gid: u32 = @intCast(pw.*.pw_gid);

    const name_copy = try allocator.dupe(u8, pw_name);
    errdefer allocator.free(name_copy);
    const home_copy = try allocator.dupe(u8, home);
    errdefer allocator.free(home_copy);
    const shell_copy = try allocator.dupe(u8, shell);
    errdefer allocator.free(shell_copy);
    const gecos_copy = try allocator.dupe(u8, gecos);
    errdefer allocator.free(gecos_copy);

    var attrs = try attribute_file.loadForUser(allocator, pw_name);
    errdefer attrs.deinit(allocator);

    return EnumeratedUser{
        .name = name_copy,
        .uid = uid,
        .gid = gid,
        .home = home_copy,
        .shell = shell_copy,
        .gecos = gecos_copy,
        .attrs = attrs,
    };
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "extractGecosName takes first comma field" {
    try testing.expectEqualStrings("Vic Thacker", extractGecosName("Vic Thacker,Office,Phone"));
    try testing.expectEqualStrings("Vic Thacker", extractGecosName("Vic Thacker"));
    try testing.expectEqualStrings("", extractGecosName(""));
    try testing.expectEqualStrings("", extractGecosName(",Office"));
}

test "EnumeratedUser.displayName prefers attribute over GECOS over name" {
    var u = EnumeratedUser{
        .name = "vic",
        .uid = 1001,
        .gid = 1001,
        .home = "/home/vic",
        .shell = "/bin/sh",
        .gecos = "",
        .attrs = .{},
    };

    // No attr, no gecos: name.
    try testing.expectEqualStrings("vic", u.displayName());

    // GECOS but no attr: gecos.
    u.gecos = "Vic from GECOS";
    try testing.expectEqualStrings("Vic from GECOS", u.displayName());

    // Attr overrides everything. (Manually populate; not via parser.)
    u.attrs.display_name = "Vic from attr";
    try testing.expectEqualStrings("Vic from attr", u.displayName());

    // Don't call deinit: fields are stack literals, not heap-allocated.
}
