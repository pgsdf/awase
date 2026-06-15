// F.5.d (ADR 0026): the policy engine. Grammar version 1 parity with the
// semaaud Phase 12 durable-policy contract: line-oriented, '#' comments,
// directives default/deny_label/deny_class/allow_class/override_class/
// fallback_target/group, precedence deny_label > deny_class > allow_class >
// default, never-throwing validation with the three exact diagnostics. Plus
// the semasound-specific extension duck_gain=F (ADR 0026 Decision 5,
// operator-ruled grammar stays version 1: the parity target is the policy
// model, not parser compatibility with a retired daemon).
//
// Fixed-capacity and allocation-free, in the house style: capped rule lists
// and token lengths, a policy file capped at 64 KiB. Loaded and evaluated on
// the single accept thread only (reload-per-connection per Decision 3);
// nothing here is touched by the audio threads.

const std = @import("std");
const posix = std.posix;

pub const MAX_RULES: usize = 16; // per rule list
pub const MAX_TOKEN: usize = 32; // per token
pub const MAX_ERRORS: usize = 16;
pub const MAX_ERROR_LEN: usize = 96;
pub const MAX_FILE: usize = 64 * 1024;

const Token = struct {
    buf: [MAX_TOKEN]u8 = [_]u8{0} ** MAX_TOKEN,
    len: usize = 0,

    fn set(self: *Token, v: []const u8) void {
        const n = @min(v.len, MAX_TOKEN);
        @memcpy(self.buf[0..n], v[0..n]);
        self.len = n;
    }
    fn get(self: *const Token) []const u8 {
        return self.buf[0..self.len];
    }
};

const TokenList = struct {
    items: [MAX_RULES]Token = [_]Token{.{}} ** MAX_RULES,
    n: usize = 0,

    fn add(self: *TokenList, v: []const u8) void {
        if (self.n >= MAX_RULES) return; // silently capped; capacity is policy
        self.items[self.n].set(v);
        self.n += 1;
    }
    fn contains(self: *const TokenList, v: []const u8) bool {
        for (self.items[0..self.n]) |*t| {
            if (std.mem.eql(u8, t.get(), v)) return true;
        }
        return false;
    }
};

pub const LoadedPolicy = struct {
    policy_version: u32 = 1,
    default_allow: bool = true,
    deny_labels: TokenList = .{},
    deny_classes: TokenList = .{},
    allow_classes: TokenList = .{},
    override_classes: TokenList = .{},
    fallback_target: Token = .{},
    group_name: Token = .{},
    duck_milli: u32 = 250, // duck_gain default 0.25 (ADR 0026 Decision 5)

    errors: [MAX_ERRORS][MAX_ERROR_LEN]u8 = undefined,
    error_lens: [MAX_ERRORS]usize = [_]usize{0} ** MAX_ERRORS,
    nerrors: usize = 0,

    pub fn isValid(self: *const LoadedPolicy) bool {
        return self.nerrors == 0;
    }
    pub fn errorAt(self: *const LoadedPolicy, i: usize) []const u8 {
        return self.errors[i][0..self.error_lens[i]];
    }
    pub fn fallbackTarget(self: *const LoadedPolicy) ?[]const u8 {
        if (self.fallback_target.len == 0) return null;
        return self.fallback_target.get();
    }
    pub fn group(self: *const LoadedPolicy) ?[]const u8 {
        if (self.group_name.len == 0) return null;
        return self.group_name.get();
    }
    pub fn isOverrideClass(self: *const LoadedPolicy, class: []const u8) bool {
        return self.override_classes.contains(class);
    }

    fn addError(self: *LoadedPolicy, comptime fmt: []const u8, args: anytype) void {
        if (self.nerrors >= MAX_ERRORS) return;
        const w = std.fmt.bufPrint(self.errors[self.nerrors][0..], fmt, args) catch blk: {
            // Diagnostic longer than the slot: keep the truncated prefix.
            break :blk self.errors[self.nerrors][0..MAX_ERROR_LEN];
        };
        self.error_lens[self.nerrors] = w.len;
        self.nerrors += 1;
    }
};

pub const Decision = enum { allow, deny };

/// Parity precedence (Phase 12): deny_label, then deny_class, then
/// allow_class, then the default.
pub fn evaluate(p: *const LoadedPolicy, label: []const u8, class: []const u8) Decision {
    if (p.deny_labels.contains(label)) return .deny;
    if (p.deny_classes.contains(class)) return .deny;
    if (p.allow_classes.contains(class)) return .allow;
    return if (p.default_allow) .allow else .deny;
}

/// Parse policy text into a LoadedPolicy. NEVER fails: diagnostics are
/// collected (the three parity texts, exact) and evaluation proceeds with
/// whatever parsed, per the Phase 12 never-throw contract.
pub fn parse(text: []const u8) LoadedPolicy {
    var p = LoadedPolicy{};
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        if (line[0] == '#') continue;

        if (std.mem.startsWith(u8, line, "version=")) {
            const v = line["version=".len..];
            p.policy_version = std.fmt.parseInt(u32, v, 10) catch {
                p.addError("invalid version field", .{});
                continue;
            };
            if (p.policy_version != 1) p.addError("unsupported policy version", .{});
        } else if (std.mem.eql(u8, line, "default=allow")) {
            p.default_allow = true;
        } else if (std.mem.eql(u8, line, "default=deny")) {
            p.default_allow = false;
        } else if (std.mem.startsWith(u8, line, "deny_label=")) {
            p.deny_labels.add(line["deny_label=".len..]);
        } else if (std.mem.startsWith(u8, line, "deny_class=")) {
            p.deny_classes.add(line["deny_class=".len..]);
        } else if (std.mem.startsWith(u8, line, "allow_class=")) {
            p.allow_classes.add(line["allow_class=".len..]);
        } else if (std.mem.startsWith(u8, line, "override_class=")) {
            p.override_classes.add(line["override_class=".len..]);
        } else if (std.mem.startsWith(u8, line, "fallback_target=")) {
            p.fallback_target.set(line["fallback_target=".len..]);
        } else if (std.mem.startsWith(u8, line, "group=")) {
            p.group_name.set(line["group=".len..]);
        } else if (std.mem.startsWith(u8, line, "duck_gain=")) {
            // semasound extension (ADR 0026 D5): float in [0,1] -> milli.
            const v = line["duck_gain=".len..];
            const f = std.fmt.parseFloat(f64, v) catch {
                p.addError("unknown directive: {s}", .{line});
                continue;
            };
            if (f < 0.0 or f > 1.0) {
                p.addError("unknown directive: {s}", .{line});
                continue;
            }
            p.duck_milli = @intFromFloat(@round(f * 1000.0));
        } else {
            p.addError("unknown directive: {s}", .{line});
        }
    }
    return p;
}

/// Load a policy file. A missing file is a valid empty policy (default
/// allow, no rules), per ADR 0026 Decision 2. Read errors other than
/// absence produce a diagnostic but never a failure.
pub fn loadFile(path: []const u8) LoadedPolicy {
    var buf: [MAX_FILE]u8 = undefined;
    var path_buf = posix.toPosixPath(path) catch {
        var p = LoadedPolicy{};
        p.addError("unknown directive: <unreadable policy file>", .{});
        return p;
    };
    const fd = posix.system.open(&path_buf, .{ .ACCMODE = .RDONLY }, @as(posix.mode_t, 0));
    if (fd < 0) {
        // A missing file is a valid empty policy (ADR 0026 Decision 2);
        // any other open failure is a diagnostic, never a hard failure.
        if (posix.errno(fd) == .NOENT) return LoadedPolicy{};
        var p = LoadedPolicy{};
        p.addError("unknown directive: <unreadable policy file>", .{});
        return p;
    }
    defer _ = posix.system.close(fd);
    var n: usize = 0;
    while (n < buf.len) {
        const r = posix.read(fd, buf[n..]) catch {
            var p = LoadedPolicy{};
            p.addError("unknown directive: <unreadable policy file>", .{});
            return p;
        };
        if (r == 0) break;
        n += r;
    }
    return parse(buf[0..n]);
}

test "empty and comment-only policies are valid, default allow" {
    const p1 = parse("");
    try std.testing.expect(p1.isValid());
    try std.testing.expectEqual(Decision.allow, evaluate(&p1, "x", "y"));
    const p2 = parse("# only a comment\n\n   \n# another\n");
    try std.testing.expect(p2.isValid());
}

test "precedence: deny_label > deny_class > allow_class > default" {
    const p = parse(
        \\version=1
        \\default=deny
        \\deny_label=badapp
        \\deny_class=ads
        \\allow_class=music
    );
    // deny_label beats allow_class even if class is allowed
    try std.testing.expectEqual(Decision.deny, evaluate(&p, "badapp", "music"));
    // deny_class beats allow_class? class can't be both; deny_class checked first
    try std.testing.expectEqual(Decision.deny, evaluate(&p, "ok", "ads"));
    try std.testing.expectEqual(Decision.allow, evaluate(&p, "ok", "music"));
    // fallthrough default=deny
    try std.testing.expectEqual(Decision.deny, evaluate(&p, "ok", "podcast"));
}

test "diagnostics: exact parity texts" {
    const p1 = parse("version=zzz\n");
    try std.testing.expect(!p1.isValid());
    try std.testing.expectEqualStrings("invalid version field", p1.errorAt(0));

    const p2 = parse("version=2\n");
    try std.testing.expect(!p2.isValid());
    try std.testing.expectEqualStrings("unsupported policy version", p2.errorAt(0));

    const p3 = parse("frobnicate=yes\n");
    try std.testing.expect(!p3.isValid());
    try std.testing.expectEqualStrings("unknown directive: frobnicate=yes", p3.errorAt(0));
}

test "malformed policy still evaluates with what parsed" {
    const p = parse(
        \\version=2
        \\deny_class=ads
        \\garbage line
    );
    try std.testing.expect(!p.isValid());
    try std.testing.expectEqual(@as(usize, 2), p.nerrors);
    try std.testing.expectEqual(Decision.deny, evaluate(&p, "x", "ads"));
    try std.testing.expectEqual(Decision.allow, evaluate(&p, "x", "music"));
}

test "override, fallback, group, duck_gain extension" {
    const p = parse(
        \\override_class=alert
        \\fallback_target=null
        \\group=speakers
        \\duck_gain=0.5
    );
    try std.testing.expect(p.isValid());
    try std.testing.expect(p.isOverrideClass("alert"));
    try std.testing.expect(!p.isOverrideClass("music"));
    try std.testing.expectEqualStrings("null", p.fallbackTarget().?);
    try std.testing.expectEqualStrings("speakers", p.group().?);
    try std.testing.expectEqual(@as(u32, 500), p.duck_milli);

    const bad = parse("duck_gain=1.5\n");
    try std.testing.expect(!bad.isValid());
    try std.testing.expectEqual(@as(u32, 250), bad.duck_milli); // default kept
}
