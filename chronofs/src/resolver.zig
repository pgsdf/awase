const std = @import("std");
const stream_mod = @import("stream");
const clock_mod   = @import("clock");

const DomainStreams = stream_mod.DomainStreams;
const AudioEvent   = stream_mod.AudioEvent;
const VisualEvent  = stream_mod.VisualEvent;
const InputEvent   = stream_mod.InputEvent;
const Clock        = clock_mod.Clock;

// ============================================================================
// Resolver
// ============================================================================

/// The chronofs resolver: given a sample position `t`, answers "what was
/// the state of each domain at that point on the audio timeline?"
///
/// All resolve functions delegate to the corresponding `DomainStreams.at(t)`.
/// `currentTime()` delegates to `clock.now()` so callers can ask "what is
/// happening right now" without needing to hold the clock directly.
pub const Resolver = struct {
    streams: *DomainStreams,
    clock:   Clock,

    pub fn init(streams: *DomainStreams, clock: Clock) Resolver {
        return .{ .streams = streams, .clock = clock };
    }

    /// Current audio clock position in sample frames.
    /// Returns 0 if the clock is not valid (semaaud not running).
    pub fn currentTime(self: Resolver) u64 {
        return self.clock.now();
    }

    /// True if the audio clock is live (at least one stream has started).
    pub fn clockValid(self: Resolver) bool {
        return self.clock.isValid();
    }

    /// Most recent visual (frame_complete) event at or before `t`.
    pub fn resolveVisual(self: Resolver, t: u64) ?VisualEvent {
        const e = self.streams.visual.at(t) orelse return null;
        return e.payload;
    }

    /// Most recent input event at or before `t`.
    pub fn resolveInput(self: Resolver, t: u64) ?InputEvent {
        const e = self.streams.input.at(t) orelse return null;
        return e.payload;
    }

    /// Most recent audio lifecycle event at or before `t`.
    pub fn resolveAudio(self: Resolver, t: u64) ?AudioEvent {
        const e = self.streams.audio.at(t) orelse return null;
        return e.payload;
    }

    /// Resolve all three domains at `t` in one call.
    pub fn resolveAll(self: Resolver, t: u64) ResolvedState {
        return .{
            .t      = t,
            .audio  = self.resolveAudio(t),
            .visual = self.resolveVisual(t),
            .input  = self.resolveInput(t),
        };
    }
};

/// The resolved state of all domains at a single sample position.
pub const ResolvedState = struct {
    t:      u64,
    audio:  ?AudioEvent,
    visual: ?VisualEvent,
    input:  ?InputEvent,
};

// ============================================================================
// JSON ingestion helpers
// ============================================================================
//
// Each ingest function parses one JSON-lines event from a subsystem's stdout
// and appends it to the appropriate stream.
//
// The unified schema guarantees:
//   {"type":"...","subsystem":"...","session":"...","seq":N,
//    "ts_wall_ns":N,"ts_audio_samples":N|null,...}
//
// We extract `ts_audio_samples` as the timeline index `t`.
// Events with `ts_audio_samples: null` are silently skipped: they have no
// position on the audio timeline.
//
// Unknown `type` values produce error.UnknownEventType, which callers ignore.

pub const IngestError = error{
    MissingField,
    InvalidNumber,
    NullAudioSamples,
    UnknownEventType,
};

/// Extract the string value of a JSON field from a flat JSON line.
/// Looks for `"key":"<value>"`; the value is the content between the quotes
/// immediately after the colon.  Returns a slice into `line`.
fn extractString(line: []const u8, key: []const u8) ![]const u8 {
    var pat_buf: [64]u8 = undefined;
    const pat = std.fmt.bufPrint(&pat_buf, "\"{s}\":\"", .{key}) catch
        return error.MissingField;
    const idx = std.mem.indexOf(u8, line, pat) orelse return error.MissingField;
    const start = idx + pat.len;
    const end = std.mem.indexOfScalarPos(u8, line, start, '"') orelse
        return error.MissingField;
    return line[start..end];
}

/// Extract a u64 value: handles `"key":123` and `"key": 123`.
fn extractU64(line: []const u8, key: []const u8) !u64 {
    var pat_buf: [64]u8 = undefined;
    const pat = std.fmt.bufPrint(&pat_buf, "\"{s}\":", .{key}) catch
        return error.MissingField;
    const idx = std.mem.indexOf(u8, line, pat) orelse return error.MissingField;
    var i = idx + pat.len;
    while (i < line.len and line[i] == ' ') : (i += 1) {}
    var end = i;
    while (end < line.len and std.ascii.isDigit(line[end])) : (end += 1) {}
    if (end == i) return error.InvalidNumber;
    return std.fmt.parseInt(u64, line[i..end], 10) catch error.InvalidNumber;
}

/// Extract a u32 value.
fn extractU32(line: []const u8, key: []const u8) !u32 {
    const v = try extractU64(line, key);
    return @intCast(v);
}

/// Extract `ts_audio_samples`: returns error.NullAudioSamples if the value
/// is the literal `null`, or error.MissingField if the key is absent.
fn extractAudioSamples(line: []const u8) !u64 {
    var pat_buf: [64]u8 = undefined;
    const pat = std.fmt.bufPrint(&pat_buf, "\"ts_audio_samples\":", .{}) catch
        return error.MissingField;
    const idx = std.mem.indexOf(u8, line, pat) orelse return error.MissingField;
    var i = idx + pat.len;
    while (i < line.len and line[i] == ' ') : (i += 1) {}
    // Check for null
    if (std.mem.startsWith(u8, line[i..], "null")) return error.NullAudioSamples;
    // Parse integer
    var end = i;
    while (end < line.len and std.ascii.isDigit(line[end])) : (end += 1) {}
    if (end == i) return error.InvalidNumber;
    return std.fmt.parseInt(u64, line[i..end], 10) catch error.InvalidNumber;
}

/// Ingest one JSON-lines event from semadraw into the visual stream.
/// Recognised types: frame_complete.
/// client_connected, client_disconnected, surface_created, surface_destroyed
/// are skipped (not relevant to the visual timeline).
pub fn ingestSemadrawLine(streams: *DomainStreams, line: []const u8) !void {
    const t = extractAudioSamples(line) catch |e| switch (e) {
        error.NullAudioSamples => return,
        else => return e,
    };

    const event_type = try extractString(line, "type");
    if (!std.mem.eql(u8, event_type, "frame_complete"))
        return error.UnknownEventType;

    const surface_id    = try extractU32(line, "surface_id");
    const frame_number  = extractU64(line, "frame_number") catch 0;

    streams.appendVisual(t, .{
        .surface_id   = surface_id,
        .frame_number = frame_number,
    });
}

// ============================================================================
// Tests
// ============================================================================

test "Resolver resolveVisual returns most recent frame at or before t" {
    var ds = DomainStreams.init();
    ds.appendVisual(1000, .{ .surface_id = 1, .frame_number = 1 });
    ds.appendVisual(2000, .{ .surface_id = 1, .frame_number = 2 });
    ds.appendVisual(3000, .{ .surface_id = 1, .frame_number = 3 });

    const mock = clock_mod.MockClock.init(48_000);
    _ = mock;
    // Use a real Clock in invalid state (no semaaud) for the resolver.
    const clk = Clock.init("/var/run/sema/clock_c3_test_absent");
    defer clk.deinit();

    const r = Resolver.init(&ds, clk);

    // Exactly on timestamp.
    const v1 = r.resolveVisual(1000).?;
    try std.testing.expectEqual(@as(u64, 1), v1.frame_number);

    // Between frames: returns most recent.
    const v2 = r.resolveVisual(1500).?;
    try std.testing.expectEqual(@as(u64, 1), v2.frame_number);

    const v3 = r.resolveVisual(2001).?;
    try std.testing.expectEqual(@as(u64, 2), v3.frame_number);

    // Before any frame.
    const v0 = r.resolveVisual(500);
    try std.testing.expect(v0 == null);
}

test "Resolver resolveInput" {
    var ds = DomainStreams.init();
    ds.appendInput(500,  InputEvent.fromType("mouse_move", "pointer:rel-0"));
    ds.appendInput(1000, InputEvent.fromType("key_down", "keyboard:0"));
    ds.appendInput(1500, InputEvent.fromType("touch_down", "touch:0"));

    const clk = Clock.init("/var/run/sema/clock_c3_test_absent");
    defer clk.deinit();
    const r = Resolver.init(&ds, clk);

    const inp1 = r.resolveInput(750).?;
    try std.testing.expectEqualStrings("mouse_move", inp1.typeName());

    const inp2 = r.resolveInput(1000).?;
    try std.testing.expectEqualStrings("key_down", inp2.typeName());

    const inp3 = r.resolveInput(2000).?;
    try std.testing.expectEqualStrings("touch_down", inp3.typeName());
}

test "Resolver resolveAudio" {
    var ds = DomainStreams.init();
    ds.appendAudio(0,     .{ .stream_id = 1, .samples_written = 0,     .active = true  });
    ds.appendAudio(48000, .{ .stream_id = 1, .samples_written = 48000, .active = false });

    const clk = Clock.init("/var/run/sema/clock_c3_test_absent");
    defer clk.deinit();
    const r = Resolver.init(&ds, clk);

    const a1 = r.resolveAudio(1000).?;
    try std.testing.expect(a1.active);

    const a2 = r.resolveAudio(48000).?;
    try std.testing.expect(!a2.active);
}

test "ingestSemadrawLine frame_complete" {
    var ds = DomainStreams.init();
    const line =
        \\{"type":"frame_complete","subsystem":"semadraw","session":"deadbeef","seq":7,"ts_wall_ns":3000,"ts_audio_samples":72000,"surface_id":2,"frame_number":5,"backend":"software"}
    ;
    try ingestSemadrawLine(&ds, line);

    const e = ds.visual.at(72000).?;
    try std.testing.expectEqual(@as(u32, 2), e.payload.surface_id);
    try std.testing.expectEqual(@as(u64, 5), e.payload.frame_number);
}

test "ingestSemadrawLine unknown type returns error" {
    var ds = DomainStreams.init();
    const line =
        \\{"type":"client_connected","subsystem":"semadraw","session":"deadbeef","seq":1,"ts_wall_ns":1000,"ts_audio_samples":1000,"client_id":1}
    ;
    const result = ingestSemadrawLine(&ds, line);
    try std.testing.expectError(error.UnknownEventType, result);
    try std.testing.expect(ds.visual.isEmpty());
}

test "resolveAll returns state for all domains" {
    var ds = DomainStreams.init();
    ds.appendAudio(1000,  .{ .stream_id = 1, .samples_written = 1000,  .active = true });
    ds.appendVisual(1200, .{ .surface_id = 3, .frame_number = 10 });
    ds.appendInput(1100,  InputEvent.fromType("key_down", "keyboard:0"));

    const clk = Clock.init("/var/run/sema/clock_c3_test_absent");
    defer clk.deinit();
    const r = Resolver.init(&ds, clk);

    const state = r.resolveAll(1500);
    try std.testing.expectEqual(@as(u64, 1500), state.t);
    try std.testing.expect(state.audio.?.active);
    try std.testing.expectEqual(@as(u64, 10), state.visual.?.frame_number);
    try std.testing.expectEqualStrings("key_down", state.input.?.typeName());
}
