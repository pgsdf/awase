// gesture_inspect: connect to semadrawd, register a surface, print
// every key/mouse/gesture event the daemon sends. Intended for
// AD-2a Phase 2.5 verification on bare metal: drives the canonical
// click / double-click / modifier / multi-touch scenarios from the
// receive side and dumps the wire to stdout in a human-readable
// (and grep-friendly) form.
//
// Output format: one event per line, colon-separated fields.
//   event_kind=<kind> [field=value ...]
// Designed to pipe through grep / awk for verification scripts.
//
// Usage:
//   gesture_inspect [--filter mouse|gesture|all] [--width N] [--height N]
//
// Flags:
//   --filter mouse    Only print mouse_event lines (drop key/gesture).
//   --filter gesture  Only print gesture_event lines.
//   --filter all      Print everything (default).
//   --width N         Surface width in pixels (default 400).
//   --height N        Surface height in pixels (default 300).
//   --help            Print this message and exit.
//
// Exit conditions:
//   - Ctrl-C: clean shutdown.
//   - daemon disconnects: prints "event_kind=disconnected" and exits 0.
//   - connect/create-surface failure: error to stderr, exit 1.

const std = @import("std");
const compat = @import("compat");
const posix = std.posix;
const semadraw_client = @import("semadraw_client");
const protocol = semadraw_client.protocol;

const Connection = semadraw_client.Connection;
const Surface = semadraw_client.Surface;
const Event = semadraw_client.Event;
const ParsedGesture = semadraw_client.ParsedGesture;
const GesturePayload = semadraw_client.GesturePayload;

// ============================================================================
// Output sink (stdout / stderr direct writes; no log-level prefix)
// ============================================================================

fn writeOut(comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
    compat.fs.stdout().writeAll(s) catch {};
}

fn writeErr(comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
    compat.fs.stderr().writeAll(s) catch {};
}

// ============================================================================
// CLI args
// ============================================================================

const Filter = enum { all, mouse, gesture };

const Args = struct {
    filter: Filter = .all,
    width: f32 = 400.0,
    height: f32 = 300.0,
};

fn parseArgs(iter: *compat.args.Iterator) !Args {
    var args = Args{};
    _ = iter.next(); // skip argv[0]

    while (iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printHelp();
            std.process.exit(0);
        } else if (std.mem.eql(u8, arg, "--filter")) {
            const v = iter.next() orelse return error.MissingFilterValue;
            args.filter = if (std.mem.eql(u8, v, "all"))
                .all
            else if (std.mem.eql(u8, v, "mouse"))
                .mouse
            else if (std.mem.eql(u8, v, "gesture"))
                .gesture
            else
                return error.InvalidFilterValue;
        } else if (std.mem.eql(u8, arg, "--width")) {
            const v = iter.next() orelse return error.MissingWidthValue;
            args.width = std.fmt.parseFloat(f32, v) catch return error.InvalidWidthValue;
        } else if (std.mem.eql(u8, arg, "--height")) {
            const v = iter.next() orelse return error.MissingHeightValue;
            args.height = std.fmt.parseFloat(f32, v) catch return error.InvalidHeightValue;
        } else {
            writeErr("unknown argument: {s}\n", .{arg});
            return error.UnknownArgument;
        }
    }
    return args;
}

fn printHelp() void {
    const help =
        \\gesture_inspect: print every event the daemon sends to a focused surface.
        \\
        \\Usage: gesture_inspect [options]
        \\
        \\Options:
        \\  --filter all|mouse|gesture   Event kinds to print (default: all)
        \\  --width N                    Surface width  (default: 400)
        \\  --height N                   Surface height (default: 300)
        \\  --help                       Print this message
        \\
        \\Phase 2.5 verification: see semadraw/docs/PHASE_2_5_VERIFICATION.md
        \\for the canonical input scenarios and expected output lines.
        \\
    ;
    compat.fs.stdout().writeAll(help) catch {};
}

// ============================================================================
// Event formatting
// ============================================================================

fn formatModifiers(buf: []u8, modifiers: u8) ![]const u8 {
    // Bit 0 = SHIFT, 1 = ALT, 2 = CTRL, 3 = META (matches GestureFlags
    // by construction; see semadrawd's last_modifiers doc).
    var w = std.Io.Writer.fixed(buf);
    var first = true;
    if ((modifiers & 0x01) != 0) {
        if (!first) try w.writeByte('+');
        try w.writeAll("shift");
        first = false;
    }
    if ((modifiers & 0x02) != 0) {
        if (!first) try w.writeByte('+');
        try w.writeAll("alt");
        first = false;
    }
    if ((modifiers & 0x04) != 0) {
        if (!first) try w.writeByte('+');
        try w.writeAll("ctrl");
        first = false;
    }
    if ((modifiers & 0x08) != 0) {
        if (!first) try w.writeByte('+');
        try w.writeAll("meta");
        first = false;
    }
    if (first) try w.writeAll("none");
    return w.buffered();
}

fn formatGestureFlags(buf: []u8, flags: protocol.GestureFlags) ![]const u8 {
    // Repack into the same u8 bit layout last_modifiers uses, then
    // delegate. Keeps "shift+ctrl" output identical between mouse
    // and gesture event lines (operator can grep one regex for
    // both).
    var packed_bits: u8 = 0;
    if (flags.shift) packed_bits |= 0x01;
    if (flags.alt) packed_bits |= 0x02;
    if (flags.ctrl) packed_bits |= 0x04;
    if (flags.meta) packed_bits |= 0x08;
    return formatModifiers(buf, packed_bits);
}

fn printKey(kp: protocol.KeyPressMsg) void {
    var mod_buf: [64]u8 = undefined;
    const mods = formatModifiers(&mod_buf, kp.modifiers) catch "?";
    writeOut(
        "event_kind=key surface={d} key_code={d} pressed={d} modifiers={s}\n",
        .{ kp.surface_id, kp.key_code, kp.pressed, mods },
    );
}

fn printMouse(me: protocol.MouseEventMsg) void {
    var mod_buf: [64]u8 = undefined;
    const mods = formatModifiers(&mod_buf, me.modifiers) catch "?";
    const ev_str = switch (me.event_type) {
        .press => "press",
        .release => "release",
        .motion => "motion",
    };
    const btn_str = switch (me.button) {
        .left => "left",
        .middle => "middle",
        .right => "right",
        .scroll_up => "scroll_up",
        .scroll_down => "scroll_down",
        .scroll_left => "scroll_left",
        .scroll_right => "scroll_right",
        .button4 => "button4",
        .button5 => "button5",
    };
    writeOut(
        "event_kind=mouse surface={d} type={s} button={s} x={d} y={d} modifiers={s}\n",
        .{ me.surface_id, ev_str, btn_str, me.x, me.y, mods },
    );
}

fn gestureTypeStr(t: protocol.GestureType) []const u8 {
    return switch (t) {
        .n_click => "n_click",
        .drag_start => "drag_start",
        .drag_move => "drag_move",
        .drag_end => "drag_end",
        .tap => "tap",
        .scroll_begin => "scroll_begin",
        .two_finger_scroll => "two_finger_scroll",
        .scroll_end => "scroll_end",
        .pinch_begin => "pinch_begin",
        .pinch => "pinch",
        .pinch_end => "pinch_end",
        .three_finger_swipe_begin => "three_finger_swipe_begin",
        .three_finger_swipe => "three_finger_swipe",
        .three_finger_swipe_end => "three_finger_swipe_end",
        .intent_hint => "intent_hint",
        _ => "unknown",
    };
}

fn phaseStr(p: protocol.GesturePhase) []const u8 {
    return switch (p) {
        .begin => "begin",
        .update => "update",
        .end => "end",
        .cancel => "cancel",
        _ => "unknown",
    };
}

fn printGesture(g: ParsedGesture) void {
    var mod_buf: [64]u8 = undefined;
    const mods = formatGestureFlags(&mod_buf, g.header.flags) catch "?";

    // Header fields are always printed; per-variant payload follows
    // as additional name=value pairs.
    var payload_buf: [256]u8 = undefined;
    const payload_str = formatGesturePayload(&payload_buf, g.payload) catch "payload=?";

    writeOut(
        "event_kind=gesture type={s} phase={s} surface={d} fingers={d} modifiers={s} t_current_ns={d} {s}\n",
        .{
            gestureTypeStr(g.header.gesture_type),
            phaseStr(g.header.phase),
            g.header.surface_id,
            g.header.finger_count,
            mods,
            g.header.t_current,
            payload_str,
        },
    );
}

fn formatGesturePayload(buf: []u8, payload: GesturePayload) ![]const u8 {
    var w = std.Io.Writer.fixed(buf);
    switch (payload) {
        .n_click => |p| try w.print("button={d} count={d} x={d} y={d}", .{ p.button, p.count, p.x, p.y }),
        .drag_start, .drag_move, .drag_end, .tap => |p| try w.print(
            "contact_id={d} x={d} y={d}",
            .{ p.contact_id, p.x, p.y },
        ),
        .scroll_begin, .scroll_end, .pinch_end, .three_finger_swipe_end => try w.writeAll("payload=none"),
        .two_finger_scroll => |p| try w.print("dx={d} dy={d}", .{ p.dx, p.dy }),
        .pinch_begin => |p| try w.print(
            "delta={d} scale={d:.4}",
            .{ p.delta, p.scale_factor },
        ),
        .pinch => |p| {
            const dir_str = switch (p.direction) {
                .in => "in",
                .out => "out",
                _ => "?",
            };
            try w.print("delta={d} scale={d:.4} direction={s}", .{ p.delta, p.scale_factor, dir_str });
        },
        .three_finger_swipe_begin, .three_finger_swipe => |p| {
            const axis_str = switch (p.axis_locked) {
                .none => "none",
                .horizontal => "horizontal",
                .vertical => "vertical",
                _ => "?",
            };
            try w.print(
                "dx={d} dy={d} total_dx={d} total_dy={d} axis={s} confidence={d}",
                .{ p.dx, p.dy, p.total_dx, p.total_dy, axis_str, p.confidence },
            );
        },
        .intent_hint => |p| {
            const g_str = switch (p.gesture) {
                .two_finger_scroll => "two_finger_scroll",
                .pinch => "pinch",
                .three_finger_swipe => "three_finger_swipe",
                _ => "?",
            };
            const a_str = switch (p.axis) {
                .none => "none",
                .horizontal => "horizontal",
                .vertical => "vertical",
                .in => "in",
                .out => "out",
                _ => "?",
            };
            try w.print("predicted={s} axis={s} confidence={d}", .{ g_str, a_str, p.confidence });
        },
    }
    return w.buffered();
}

// ============================================================================
// Main
// ============================================================================

pub fn main(init: std.process.Init.Minimal) !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var arg_iter = compat.args.iterator(init.args);
    const args = parseArgs(&arg_iter) catch |err| {
        writeErr("argument error: {}\nrun with --help for usage\n", .{err});
        std.process.exit(2);
    };

    writeOut("# gesture_inspect: connecting to semadrawd...\n", .{});
    var conn = Connection.connect(allocator) catch |err| {
        writeErr("failed to connect to semadrawd: {}\n", .{err});
        writeErr("hint: is the daemon running? is the socket accessible?\n", .{});
        std.process.exit(1);
    };
    defer conn.disconnect();

    writeOut("# connected; creating surface ({d}x{d})...\n", .{ args.width, args.height });
    var surface = Surface.create(conn, args.width, args.height) catch |err| {
        writeErr("failed to create surface: {}\n", .{err});
        std.process.exit(1);
    };
    defer surface.destroy();

    surface.show() catch |err| {
        writeErr("failed to show surface: {}\n", .{err});
        std.process.exit(1);
    };

    surface.commit() catch |err| {
        writeErr("failed to commit surface: {}\n", .{err});
        // Non-fatal: a surface without committed content is still a
        // routing target for input events. Continue.
        writeErr("# continuing without committed content\n", .{});
    };

    writeOut("# surface visible (id={d}); waiting for events. Ctrl-C to quit.\n", .{surface.id});

    // Main poll loop. blocks in poll() if no events are pending.
    while (true) {
        const maybe_ev = conn.poll() catch |err| {
            writeErr("poll error: {}\n", .{err});
            break;
        };
        const ev = maybe_ev orelse continue;

        switch (ev) {
            .key_press => |kp| {
                if (args.filter == .all) printKey(kp);
            },
            .mouse_event => |me| {
                if (args.filter == .all or args.filter == .mouse) printMouse(me);
            },
            .gesture_event => |g| {
                if (args.filter == .all or args.filter == .gesture) printGesture(g);
            },
            .disconnected => {
                writeOut("event_kind=disconnected\n", .{});
                break;
            },
            // Surface lifecycle, frame, error, clipboard: ignore in this
            // tool. They're not what verification is testing for.
            else => {},
        }
    }
}
