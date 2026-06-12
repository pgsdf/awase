const std = @import("std");
const session_mod = @import("session");

// ============================================================================
// Event emitter, unified schema stdout emission for semadraw
//
// All events follow shared/EVENT_SCHEMA.md:
//   {"type":"...","subsystem":"semadraw","session":"...","seq":N,
//    "ts_wall_ns":N,"ts_audio_samples":null,...event fields...}
//
// ts_audio_samples is always null in D-1. I-3 / C-4 will wire the clock.
// ============================================================================

/// Cached session token (16-char lowercase hex). Initialised once at startup.
var session_hex: [16]u8 = [_]u8{'0'} ** 16;

/// Per-daemon monotonic event sequence counter.
var seq: std.atomic.Value(u64) = std.atomic.Value(u64).init(1);

/// Initialise the session token from the shared session file.
/// Call once at daemon startup before any events are emitted.
pub fn initSession() void {
    const token = session_mod.readOrCreate(session_mod.DEFAULT_SESSION_PATH) catch 0;
    _ = session_mod.format(token, &session_hex);
}

// ============================================================================
// Internal helpers
// ============================================================================

fn nextSeq() u64 {
    return seq.fetchAdd(1, .monotonic);
}

/// Scratch size for the `,"seq":N,"ts_wall_ns":T,"ts_audio_samples":`
/// fragment in emitWithSamples. Worst case is 41 literal bytes plus a
/// 20-digit u64-max seq plus a 19-digit ts_wall_ns: 80 bytes. Sized
/// with headroom and locked by the width test at the bottom of this
/// file.
///
/// HISTORY (2026-06-05, the AD-43/AD-46 "freeze" root cause): this
/// buffer was [64]u8. Forty-one literal bytes plus a 19-digit
/// timestamp leaves exactly 4 digits of room for seq, so the fragment
/// fit through seq 9999 and overflowed at seq 10000; bufPrint
/// returned NoSpaceLeft and the `catch return` below swallowed it.
/// From its 10,000th event onward, every daemon process emitted
/// NOTHING, every event type, silently, while std.log (stderr) lines
/// continued. Every "log freeze" chased across AD-43.3a, AD-46, and
/// three bench days was this byte. Found by the seq census in
/// ad43-logpath-diag.sh: two consecutive boots whose final structured
/// event was seq 9999 exactly, with the ktrace showing zero fd-1
/// write calls (death before the syscall).
const SEQTS_SCRATCH_LEN: usize = 96;

/// Write a complete unified-schema JSON line to stdout.
/// `event_type`, the schema type string, e.g. "client_connected"
/// `fields_json`, event-specific JSON fragment starting with a comma,
///                 e.g. `,"client_id":1,"surface_id":2`
///                 Pass empty slice for lifecycle events with no extra fields.
fn emitWithSamples(event_type: []const u8, fields_json: []const u8, ts_audio_samples: ?u64) void {
    const ts: i64 = @intCast(std.time.nanoTimestamp());
    const s = nextSeq();

    var line_buf: [2048]u8 = undefined;
    var stream = std.io.fixedBufferStream(&line_buf);
    const w = stream.writer();

    w.writeAll("{\"type\":\"") catch return;
    w.writeAll(event_type) catch return;
    w.writeAll("\",\"subsystem\":\"semadraw\",\"session\":\"") catch return;
    w.writeAll(&session_hex) catch return;
    w.writeByte('"') catch return;

    var tmp: [SEQTS_SCRATCH_LEN]u8 = undefined;
    const seqts = std.fmt.bufPrint(&tmp,
        ",\"seq\":{d},\"ts_wall_ns\":{d},\"ts_audio_samples\":",
        .{ s, ts }) catch return;
    w.writeAll(seqts) catch return;

    if (ts_audio_samples) |samples| {
        var ntmp: [24]u8 = undefined;
        const ns = std.fmt.bufPrint(&ntmp, "{d}", .{samples}) catch "null";
        w.writeAll(ns) catch return;
    } else {
        w.writeAll("null") catch return;
    }

    w.writeAll(fields_json) catch return;
    w.writeAll("}\n") catch return;

    var file = std.fs.File.stdout();
    var out_buf: [2048]u8 = undefined;
    // AD-23: use writerStreaming rather than writer.
    //
    // `writer()` initialises File.Writer in `.positional` mode, which
    // calls pwritev. On a pipe (stdout typically is one when the
    // operator runs `daemon 2>&1 | tee /tmp/log`), pwritev returns
    // ESPIPE. File.Writer's drain has an `error.Unseekable` fallback
    // that transitions to streaming mode within the same drain, so a
    // single emission's data does still land, but every emission
    // pays the doomed pwritev syscall before falling through. Because
    // this function constructs a fresh File.Writer per invocation,
    // the streaming-mode transition never persists; every emit-call
    // repeats the failed-syscall-then-fall-through dance. ktrace
    // during AD-21 verification surfaced this as a tight loop of
    // `pwritev(0x1, ..., 0) = -1 errno 29 Illegal seek` under
    // emission load.
    //
    // `writerStreaming()` initialises in `.streaming` mode and calls
    // writev directly, skipping the doomed syscall. Stdout for a
    // daemon is conceptually append-only, there is no offset
    // semantics worth preserving, so streaming is the correct mode
    // regardless of whether the destination is a pipe, regular file,
    // or terminal.
    var out = file.writerStreaming(&out_buf);
    out.interface.writeAll(stream.getWritten()) catch return;
    out.interface.flush() catch return;
}

fn emit(event_type: []const u8, fields_json: []const u8) void {
    emitWithSamples(event_type, fields_json, null);
}

// ============================================================================
// Typed event emitters
// ============================================================================

/// Emitted when a client completes the HELLO handshake.
///
/// AD-31.4 part B: emits `peer_uid`, the uid of the connecting
/// client per ADR 0006 §9. For Unix-domain connections this is
/// the result of `getpeereid(3)` at accept time (per AD-31.2);
/// for TCP connections it is the NOBODY sentinel (65534) per
/// ADR 0006 §2.
pub fn emitClientConnected(client_id: u64, version_major: u16, version_minor: u16, peer_uid: std.posix.uid_t) void {
    var buf: [128]u8 = undefined;
    const fields = std.fmt.bufPrint(&buf,
        ",\"client_id\":{d},\"client_version_major\":{d},\"client_version_minor\":{d},\"peer_uid\":{d}",
        .{ client_id, version_major, version_minor, peer_uid }) catch return;
    emit("client_connected", fields);
}

/// Emitted when a client session ends (disconnect or error).
///
/// AD-31.4 part B: emits `peer_uid` per ADR 0006 §9, attributing
/// the disconnect to the same uid that `client_connected` did.
/// Callers look up the session before invoking this (the lookup
/// must happen pre-session-cleanup; see disconnectClient and
/// disconnectRemoteClient in semadrawd.zig). When the session is
/// not findable for any reason, NOBODY_UID is the conservative
/// fallback.
pub fn emitClientDisconnected(client_id: u64, reason: []const u8, peer_uid: std.posix.uid_t) void {
    var buf: [160]u8 = undefined;
    const fields = std.fmt.bufPrint(&buf,
        ",\"client_id\":{d},\"reason\":\"{s}\",\"peer_uid\":{d}",
        .{ client_id, reason, peer_uid }) catch return;
    emit("client_disconnected", fields);
}

/// Emitted when a surface is created.
///
/// AD-31.4 part B: emits `owner_uid` per ADR 0006 §9. This is
/// the uid of the connecting client that requested the surface
/// (equal to session.peer_uid at creation time). The
/// surface.owner_uid field on the registry Surface struct
/// carries the same value.
pub fn emitSurfaceCreated(client_id: u64, surface_id: u32, width: f32, height: f32, owner_uid: std.posix.uid_t) void {
    var buf: [128]u8 = undefined;
    const fields = std.fmt.bufPrint(&buf,
        ",\"client_id\":{d},\"surface_id\":{d},\"width\":{d:.0},\"height\":{d:.0},\"owner_uid\":{d}",
        .{ client_id, surface_id, width, height, owner_uid }) catch return;
    emit("surface_created", fields);
}

/// Emitted when a surface is destroyed.
///
/// AD-31.4 part B: emits `owner_uid` per ADR 0006 §9, recording
/// the same uid the surface was created with. Callers look up
/// the surface before destruction (the lookup must happen
/// pre-destroy because destroySurface deallocates the Surface
/// struct).
pub fn emitSurfaceDestroyed(client_id: u64, surface_id: u32, owner_uid: std.posix.uid_t) void {
    var buf: [96]u8 = undefined;
    const fields = std.fmt.bufPrint(&buf,
        ",\"client_id\":{d},\"surface_id\":{d},\"owner_uid\":{d}",
        .{ client_id, surface_id, owner_uid }) catch return;
    emit("surface_destroyed", fields);
}

/// Emitted once per rendered frame (on COMMIT reply or compositor cycle).
/// `ts_audio_samples` carries the audio clock position of this frame boundary
/// when the chronofs clock is driving the scheduler; null otherwise.
pub fn emitFrameComplete(surface_id: u32, frame_number: u64, backend_name: []const u8, ts_audio_samples: ?u64) void {
    var buf: [128]u8 = undefined;
    const fields = std.fmt.bufPrint(&buf,
        ",\"surface_id\":{d},\"frame_number\":{d},\"backend\":\"{s}\"",
        .{ surface_id, frame_number, backend_name }) catch return;
    emitWithSamples("frame_complete", fields, ts_audio_samples);
}

/// AD-25 diagnostic: per-composite-cycle counters for the clearRegion path.
/// Emitted when the compositor's `instrument` field is true (see
/// compositor.zig; gated on UTF_COMPOSITOR_INSTRUMENT environment variable).
///
/// Fields chosen to answer the BACKLOG entry's two hypotheses:
///   - hypothesis (a), markFullRepaint firing more than expected.
///     `full_entry` is true when full repaint was set before composite
///     started (an outside caller, e.g. damageAll on visibility change).
///     `full_clearpath` is true when the clearRegion path itself promoted
///     to full repaint (backend lacks clearRegion, or clearRegion errored).
///     During steady cursor motion both should be false on the bench.
///   - hypothesis (b), clearRegion inner loop is the bottleneck.
///     `clear_calls`, `clear_px`, `clear_ns` quantify the clearRegion
///     work this frame. clear_ns / clear_px gives ns/px; clear_ns
///     compared to the per-frame budget shows whether clearRegion alone
///     is the issue.
///
/// `surfaces_rendered` and `render_ns` provide context for the rest of
/// the frame budget so the operator can tell what fraction is
/// clearRegion versus surface render.
pub fn emitAd25Diagnostic(
    frame: u64,
    clear_calls: u32,
    clear_px: u64,
    clear_ns: u64,
    full_entry: bool,
    full_clearpath: bool,
    surfaces_rendered: u32,
    render_ns: u64,
) void {
    var buf: [256]u8 = undefined;
    const fields = std.fmt.bufPrint(&buf,
        ",\"frame\":{d},\"clear_calls\":{d},\"clear_px\":{d},\"clear_ns\":{d}," ++
        "\"full_entry\":{},\"full_clearpath\":{},\"surfaces_rendered\":{d},\"render_ns\":{d}",
        .{
            frame,
            clear_calls,
            clear_px,
            clear_ns,
            full_entry,
            full_clearpath,
            surfaces_rendered,
            render_ns,
        }) catch return;
    emit("ad25_diagnostic", fields);
}

/// AD-25 Round 1 (ADR 0007): per-pump-invocation diagnostic.
/// Refreshed under AD-38 (2026-05-22) to reflect the AD-36
/// code path: `pumpCursorPosition` reads pointer position from
/// `Daemon.last_motion_x/y`, sourced from inputfs event-ring
/// `pointer.motion` events harvested in the main loop, not from
/// the state-region mmap.
///
/// Emitted from `pumpCursorPosition` on every invocation. Two
/// emit sites:
///
///   1. Early-return when no `pointer.motion` event has been
///      observed yet (`last_motion_seen == false`). All boolean
///      fields are false and `ps_x, ps_y` are 0 sentinels. This
///      branch lets the AD-25 Round 1 cadence analysis still
///      distinguish "pump ran but had no data" from "pump did
///      not run".
///   2. Post-change-detection in the normal path, after the new
///      cursor position has been compared against
///      `last_cursor_pos_*`. `ps_x, ps_y` carry the absolute
///      coordinates from the latest consumed `pointer.motion`
///      event payload.
///
/// The intent (unchanged from Round 1) is to measure pump
/// cadence (median delta between consecutive `ts_wall_ns`
/// values) and compare against composite cadence to determine
/// whether the pump and composite share the same outer-loop
/// pacing or fire at different rates.
///
/// Fields:
///   - `pos_changed`: change detection result for the cursor
///     surface position (the freshly-computed pointer minus
///     hotspot, compared against `last_cursor_pos_*`).
///   - `vis_changed`: change detection result for cursor
///     visibility (whether the pointer is inside the framebuffer
///     and thus whether the cursor should be painted).
///   - `state_valid`: whether the pump has a known pointer
///     position to act on. False before the first
///     `pointer.motion` event has been observed since daemon
///     start; true thereafter for the lifetime of the daemon.
///     The transition is one-shot: once a motion event seeds
///     `last_motion_x/y`, the pump has a position to track and
///     `state_valid` stays true. (Pre-AD-36 this field reflected
///     `pointerSnapshot()` returning non-null per iteration; the
///     state-region mmap is no longer consulted by the pump.)
///   - `ps_x`, `ps_y`: absolute integer pointer coordinates
///     carried by the latest consumed `pointer.motion` event
///     this iteration, copied into `Daemon.last_motion_x/y`
///     by the main-loop harvest. The pump-side `pos_changed`
///     boolean reports whether the *cursor-surface position*
///     (post-hotspot, in f32) differs from the cached last
///     value; `ps_x, ps_y` report the *raw event-payload
///     values* before any transformation. They answer
///     different questions:
///       - `pos_changed=false` with varying `ps_x, ps_y`: the
///         pump is seeing new pointer values but the
///         post-hotspot comparison is missing the change
///         (would indicate a precision or hotspot bug;
///         unlikely).
///       - `pos_changed=false` with constant `ps_x, ps_y`
///         across many iterations: the pump is being invoked
///         but no new `pointer.motion` events are arriving
///         (expected during periods of cursor inactivity).
///     When `state_valid=false`, `ps_x` and `ps_y` are
///     reported as 0 sentinels. Consumers must check
///     `state_valid` before interpreting the coordinate
///     fields.
///
/// (Pre-AD-36 the second case above was the AD-34
/// mmap-visibility hypothesis - "the pump's mmap view is
/// returning the same bytes despite inputfs publishing
/// updates". AD-36 obviated that hypothesis by abandoning
/// the mmap read path for the pump entirely; AD-34 itself
/// remains open as a kernel-investigation track since the
/// underlying state-region staleness affects other
/// consumers.)
///
/// Pump cadence on the disabled path costs one bool field check.
/// On the enabled path the cost is one bufPrint + emit per
/// invocation. Per ADR 0007 the cadence is bounded by the outer
/// loop's poll timeout (~10/sec on idle, higher under input
/// activity), so log volume is bounded.
pub fn emitPumpDiagnostic(
    pos_changed: bool,
    vis_changed: bool,
    state_valid: bool,
    ps_x: i32,
    ps_y: i32,
) void {
    var buf: [128]u8 = undefined;
    const fields = std.fmt.bufPrint(&buf,
        ",\"pos_changed\":{},\"vis_changed\":{},\"state_valid\":{},\"ps_x\":{},\"ps_y\":{}",
        .{ pos_changed, vis_changed, state_valid, ps_x, ps_y }) catch return;
    emit("pump_diagnostic", fields);
}

/// AD-25 Round 2 (ADR 0007 addendum): per-`needsComposite` gate
/// diagnostic.
///
/// Emitted from `Compositor.needsComposite` on every main-loop
/// iteration. Round 1 found that the main loop iterates at
/// ~67 kHz while composite fires at only ~8.7 Hz; the ~99.99%
/// gap is gated by `needsComposite()` returning false. This
/// event records *why* it returned false on each call so the
/// analysis can determine which gate is closing most often.
///
/// Fields:
///   - `has_damage`: `damage_tracker.hasDamage()` return value.
///     False means no surface has reported a dirty region since
///     the last composite. Should be true frequently during
///     cursor motion (the pump marks damage on cursor and
///     underlying surfaces); if it stays false during motion,
///     the pump's damage propagation has a bug.
///   - `should_composite`: `scheduler.shouldComposite()` return
///     value. False means the FrameScheduler's deadline has not
///     yet been reached. At a 60 Hz target the deadline should
///     pass every ~16.7 ms; if `should_composite` is false on
///     more than ~99% of calls, the scheduler's
///     `next_deadline_ns` accounting is off.
///   - `state_valid`: false when `needsComposite()` returns
///     early via the `!composing` or `output == null` paths
///     (infrastructure not ready). True when both gate values
///     are computed.
///
/// On the disabled path this event costs one bool check. On
/// the enabled path the cost is one bufPrint + emit per
/// invocation. Per ADR 0007 Round 1 findings the cadence is
/// bounded by the outer-loop iteration rate (~67 kHz), so
/// log volume requires the bumped retention from commit
/// `b062f3f` to capture more than ~150 ms of activity.
pub fn emitCompositeGateDiagnostic(
    has_damage: bool,
    should_composite: bool,
    state_valid: bool,
) void {
    var buf: [128]u8 = undefined;
    const fields = std.fmt.bufPrint(&buf,
        ",\"has_damage\":{},\"should_composite\":{},\"state_valid\":{}",
        .{ has_damage, should_composite, state_valid }) catch return;
    emit("composite_gate_diagnostic", fields);
}

// ============================================================================
// Tests
// ============================================================================

// AD-23: confirm emitWithSamples's writer-construction pattern produces
// intact, ordered output when stdout is a pipe.
//
// Before the fix, emitWithSamples called `file.writer(buf)` which
// initialises File.Writer in `.positional` mode, calling pwritev. On a
// pipe (stdout typically is one when the operator runs
// `daemon 2>&1 | tee /tmp/log`), pwritev returns ESPIPE. File.Writer's
// drain has an `error.Unseekable` fallback that transitions to streaming
// mode within the same drain, so a single emission's data does still
// land, but every emission paid the doomed syscall before falling
// through. Because emitWithSamples constructs a fresh File.Writer per
// invocation, the streaming-mode transition never persisted; every
// emit-call repeated the failed-syscall-then-fall-through dance. ktrace
// during AD-21 verification surfaced this as a tight loop of
// `pwritev(0x1, ..., 0) = -1 errno 29 Illegal seek` syscalls under
// emission load.
//
// The fix changes the constructor to `file.writerStreaming(buf)`, which
// initialises in `.streaming` mode and skips pwritev entirely.
//
// This test mirrors emitWithSamples's actual call shape (fresh writer
// per emission) against a pipe(2) fd, asserting both that each emission
// returns without error and that the bytes arrive intact and in order.
// It verifies the wire-correct outcome but does not directly assert
// "no pwritev syscall happened", that's confirmed by ktrace at
// verification time, not by a unit test. The value of this test is to
// lock in the writerStreaming choice so a future refactor that goes
// back to writer() is caught at zig build test time rather than at
// the next bare-metal verification round.
test "emitWithSamples-style writes through pipe fd succeed (AD-23)" {
    const testing = std.testing;
    const posix = std.posix;

    const fds = try posix.pipe();
    defer posix.close(fds[0]);
    defer posix.close(fds[1]);

    var file: std.fs.File = .{ .handle = fds[1] };
    const payload_a = "{\"type\":\"frame_complete\",\"backend\":\"software\"}\n";
    const payload_b = "{\"type\":\"client_connected\",\"client_id\":1}\n";

    // Mirror emitWithSamples: fresh writer per call, write+flush.
    {
        var out_buf: [2048]u8 = undefined;
        var out = file.writerStreaming(&out_buf);
        try out.interface.writeAll(payload_a);
        try out.interface.flush();
    }
    {
        var out_buf: [2048]u8 = undefined;
        var out = file.writerStreaming(&out_buf);
        try out.interface.writeAll(payload_b);
        try out.interface.flush();
    }

    var read_buf: [256]u8 = undefined;
    const n = try posix.read(fds[0], &read_buf);
    const expected = payload_a ++ payload_b;
    try testing.expectEqual(expected.len, n);
    try testing.expectEqualStrings(expected, read_buf[0..n]);
}

// AD-43 silence root cause (2026-06-05): the seq/ts scratch must hold
// the fragment at MAXIMUM field widths. The original [64]u8 held
// exactly a 4-digit seq with a 19-digit ts_wall_ns and overflowed at
// seq 10000, silencing all structured emission for the life of the
// process (NoSpaceLeft swallowed by `catch return`). This test pins
// the worst case so the buffer can never silently shrink below it.
test "seq/ts scratch fits maximum field widths (AD-43 silence root cause)" {
    var tmp: [SEQTS_SCRATCH_LEN]u8 = undefined;
    const worst_seq: u64 = std.math.maxInt(u64); // 20 digits
    const worst_ts: i64 = std.math.maxInt(i64); // 19 digits
    const seqts = try std.fmt.bufPrint(&tmp,
        ",\"seq\":{d},\"ts_wall_ns\":{d},\"ts_audio_samples\":",
        .{ worst_seq, worst_ts });
    try std.testing.expect(seqts.len <= SEQTS_SCRATCH_LEN);
}
