// inputdump: read and print the inputfs publication regions
// (state, events, focus). This is the long-lived CLI tool that
// replaces the throwaway inputstate-check used to verify Stage
// C.2 and C.3.
//
// Usage:
//   inputdump <subcommand> [options]
//
// Subcommands:
//   state     Print the materialised state region.
//   events    Drain and print the event ring.
//   watch     Live tail of state and events together.
//   devices   Print only the device inventory from the state region.
//
// Run "inputdump --help" or "inputdump <subcommand> --help" for
// the full option list.

const std = @import("std");
const input = @import("input");

// ============================================================================
// Output sink
// ============================================================================
//
// Avoids a gratuitous dependency on std.log: writes go straight to
// stdout / stderr via posix.write of the formatted bytes. This keeps
// the tool's output format under our explicit control (no log-level
// prefixes, no timestamps unless we add them ourselves).

fn writeOut(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const slice = std.fmt.bufPrint(&buf, fmt, args) catch {
        // bufPrint failed (output too long for the buffer); drop the
        // message rather than write uninitialized bytes. A truncation
        // marker keeps the failure visible but avoids leaking stack.
        const marker = "<inputdump: output truncated>\n";
        _ = std.posix.write(std.posix.STDOUT_FILENO, marker) catch {};
        return;
    };
    _ = std.posix.write(std.posix.STDOUT_FILENO, slice) catch {};
}

fn writeErr(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const slice = std.fmt.bufPrint(&buf, fmt, args) catch {
        const marker = "<inputdump: error message truncated>\n";
        _ = std.posix.write(std.posix.STDERR_FILENO, marker) catch {};
        return;
    };
    _ = std.posix.write(std.posix.STDERR_FILENO, slice) catch {};
}

// ============================================================================
// Subcommand and option model
// ============================================================================

const Subcommand = enum {
    state,
    events,
    watch,
    devices,
};

const RoleFilter = enum {
    any,
    pointer,
    keyboard,
    touch,
    pen,
    lighting,
    lifecycle,

    fn fromString(s: []const u8) ?RoleFilter {
        if (std.mem.eql(u8, s, "pointer")) return .pointer;
        if (std.mem.eql(u8, s, "keyboard")) return .keyboard;
        if (std.mem.eql(u8, s, "touch")) return .touch;
        if (std.mem.eql(u8, s, "pen")) return .pen;
        if (std.mem.eql(u8, s, "lighting")) return .lighting;
        if (std.mem.eql(u8, s, "lifecycle")) return .lifecycle;
        return null;
    }

    fn matches(self: RoleFilter, role: u8) bool {
        return switch (self) {
            .any => true,
            .pointer => role == input.SOURCE_POINTER,
            .keyboard => role == input.SOURCE_KEYBOARD,
            .touch => role == input.SOURCE_TOUCH,
            .pen => role == input.SOURCE_PEN,
            .lighting => role == input.SOURCE_LIGHTING,
            .lifecycle => role == input.SOURCE_DEVICE_LIFECYCLE,
        };
    }
};

const EventTypeFilter = struct {
    // null means no filter; otherwise the event_type must match
    // exactly. The valid event type set depends on the role
    // filter (e.g. "motion" only makes sense with .pointer).
    value: ?u8 = null,

    fn parse(s: []const u8, role: RoleFilter) !EventTypeFilter {
        // Pointer events.
        if (role == .pointer or role == .any) {
            if (std.mem.eql(u8, s, "motion")) return .{ .value = 1 };
            if (std.mem.eql(u8, s, "button_down")) return .{ .value = 2 };
            if (std.mem.eql(u8, s, "button_up")) return .{ .value = 3 };
            if (std.mem.eql(u8, s, "scroll")) return .{ .value = 4 };
        }
        // Keyboard events.
        if (role == .keyboard or role == .any) {
            if (std.mem.eql(u8, s, "key_down")) return .{ .value = 1 };
            if (std.mem.eql(u8, s, "key_up")) return .{ .value = 2 };
        }
        // Lifecycle events.
        if (role == .lifecycle or role == .any) {
            if (std.mem.eql(u8, s, "attach")) return .{ .value = 1 };
            if (std.mem.eql(u8, s, "detach")) return .{ .value = 2 };
        }
        return error.UnknownEventType;
    }

    fn matches(self: EventTypeFilter, event_type: u8) bool {
        if (self.value) |v| return v == event_type;
        return true;
    }
};

const Options = struct {
    sub: Subcommand,

    // common
    json: bool = false,
    verbose: bool = false,
    help: bool = false,

    // state
    watch_changes: bool = false,
    all_slots: bool = false,

    // events
    from_seq: ?u64 = null,
    role: RoleFilter = .any,
    device: ?u16 = null,
    event_type: EventTypeFilter = .{},
    stats: bool = false,

    // watch / events
    interval_ms: u64 = 0, // 0 means "use the per-subcommand default"
};

const usage_top =
    \\inputdump  read and print inputfs publication regions
    \\
    \\Usage:
    \\  inputdump <subcommand> [options]
    \\
    \\Subcommands:
    \\  state     Print the materialised state region (default one-shot).
    \\  events    Drain and print the event ring.
    \\  watch     Live tail of state and events together.
    \\  devices   Print only the device inventory.
    \\
    \\Run "inputdump <subcommand> --help" for subcommand-specific options.
    \\Common options:
    \\  --json            Emit JSON instead of human-readable text.
    \\  --verbose         Multi-line per record with field names.
    \\  --help, -h        Print this help.
    \\
;

const usage_state =
    \\inputdump state  print the materialised state region
    \\
    \\Options:
    \\  --watch              Loop, print only when something changed.
    \\  --interval-ms N      Poll interval for --watch (default 250 ms).
    \\  --all-slots          Print empty device slots too (default: only populated).
    \\  --verbose            Multi-line per slot with all fields.
    \\  --json               JSON output.
    \\
;

const usage_events =
    \\inputdump events  drain and print the event ring
    \\
    \\Options:
    \\  --watch              Stream live until interrupted.
    \\  --interval-ms N      Poll interval for --watch (default 100 ms).
    \\  --from-seq N         Start from sequence N (default: current).
    \\  --role <name>        Filter by source role:
    \\                       pointer, keyboard, touch, pen, lighting, lifecycle.
    \\  --device N           Filter by device slot.
    \\  --event <name>       Filter by event type:
    \\                       motion, button_down, button_up, scroll (pointer);
    \\                       key_down, key_up (keyboard);
    \\                       attach, detach (lifecycle).
    \\                       Requires --role.
    \\  --stats              Print aggregate counters at end (or periodically
    \\                       with --watch, every 5 seconds).
    \\  --verbose            Multi-line per event with field names.
    \\  --json               JSON output (one event per line).
    \\
;

const usage_watch =
    \\inputdump watch  live tail of state + events
    \\
    \\Options:
    \\  --interval-ms N      Poll interval (default 100 ms).
    \\  --role <name>        Filter events by source role.
    \\  --device N           Filter events by device slot.
    \\  --event <name>       Filter events by type (requires --role).
    \\  --json               JSON output.
    \\
;

const usage_devices =
    \\inputdump devices  print the device inventory
    \\
    \\Options:
    \\  --all-slots          Print empty slots too.
    \\  --verbose            Multi-line per slot with all fields.
    \\  --json               JSON output.
    \\
;

fn parseSubcommand(s: []const u8) ?Subcommand {
    if (std.mem.eql(u8, s, "state")) return .state;
    if (std.mem.eql(u8, s, "events")) return .events;
    if (std.mem.eql(u8, s, "watch")) return .watch;
    if (std.mem.eql(u8, s, "devices")) return .devices;
    return null;
}

fn parseArgs(args: [][:0]u8) Options {
    if (args.len < 2) {
        writeErr("{s}", .{usage_top});
        std.process.exit(2);
    }

    // Allow --help / -h as the first positional, before any
    // subcommand was given.
    if (std.mem.eql(u8, args[1], "--help") or std.mem.eql(u8, args[1], "-h")) {
        writeOut("{s}", .{usage_top});
        std.process.exit(0);
    }

    const sub = parseSubcommand(args[1]) orelse {
        writeErr("inputdump: unknown subcommand '{s}'\n\n{s}", .{ args[1], usage_top });
        std.process.exit(2);
    };

    var opts: Options = .{ .sub = sub };

    // Pending --event needs to be deferred until we've seen --role,
    // because the valid event names depend on the role.
    var pending_event_arg: ?[]const u8 = null;

    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            opts.help = true;
        } else if (std.mem.eql(u8, a, "--json")) {
            opts.json = true;
        } else if (std.mem.eql(u8, a, "--verbose")) {
            opts.verbose = true;
        } else if (std.mem.eql(u8, a, "--watch")) {
            opts.watch_changes = true;
        } else if (std.mem.eql(u8, a, "--all-slots")) {
            opts.all_slots = true;
        } else if (std.mem.eql(u8, a, "--stats")) {
            opts.stats = true;
        } else if (std.mem.eql(u8, a, "--interval-ms")) {
            i = expectArg(args, i, "--interval-ms");
            opts.interval_ms = std.fmt.parseInt(u64, args[i], 10) catch {
                writeErr("inputdump: --interval-ms requires a non-negative integer\n", .{});
                std.process.exit(2);
            };
            if (opts.interval_ms == 0) {
                writeErr("inputdump: --interval-ms must be > 0\n", .{});
                std.process.exit(2);
            }
        } else if (std.mem.eql(u8, a, "--from-seq")) {
            i = expectArg(args, i, "--from-seq");
            opts.from_seq = std.fmt.parseInt(u64, args[i], 10) catch {
                writeErr("inputdump: --from-seq requires a non-negative integer\n", .{});
                std.process.exit(2);
            };
        } else if (std.mem.eql(u8, a, "--role")) {
            i = expectArg(args, i, "--role");
            opts.role = RoleFilter.fromString(args[i]) orelse {
                writeErr("inputdump: --role: unknown role '{s}'\n", .{args[i]});
                writeErr("  valid roles: pointer, keyboard, touch, pen, lighting, lifecycle\n", .{});
                std.process.exit(2);
            };
        } else if (std.mem.eql(u8, a, "--device")) {
            i = expectArg(args, i, "--device");
            const v = std.fmt.parseInt(u16, args[i], 10) catch {
                writeErr("inputdump: --device requires an integer slot index\n", .{});
                std.process.exit(2);
            };
            opts.device = v;
        } else if (std.mem.eql(u8, a, "--event")) {
            i = expectArg(args, i, "--event");
            pending_event_arg = args[i];
        } else {
            writeErr("inputdump: unknown argument '{s}'\n", .{a});
            std.process.exit(2);
        }
    }

    if (opts.help) {
        const text = switch (opts.sub) {
            .state => usage_state,
            .events => usage_events,
            .watch => usage_watch,
            .devices => usage_devices,
        };
        writeOut("{s}", .{text});
        std.process.exit(0);
    }

    if (pending_event_arg) |s| {
        if (opts.role == .any) {
            writeErr("inputdump: --event '{s}' requires --role to disambiguate\n", .{s});
            std.process.exit(2);
        }
        opts.event_type = EventTypeFilter.parse(s, opts.role) catch {
            writeErr("inputdump: --event: unknown event type '{s}' for role\n", .{s});
            std.process.exit(2);
        };
    }

    // Apply per-subcommand defaults for interval_ms.
    if (opts.interval_ms == 0) {
        opts.interval_ms = switch (opts.sub) {
            .state => 250,
            .events, .watch => 100,
            .devices => 0,
        };
    }

    return opts;
}

fn expectArg(args: [][:0]u8, i: usize, flag: []const u8) usize {
    if (i + 1 >= args.len) {
        writeErr("inputdump: {s} requires a value\n", .{flag});
        std.process.exit(2);
    }
    return i + 1;
}

// ============================================================================
// Formatting helpers
// ============================================================================

fn nameToSlice(name: *const [64]u8) []const u8 {
    var len: usize = 0;
    while (len < 64 and name[len] != 0) : (len += 1) {}
    return name[0..len];
}

fn deviceIdHex(id: [16]u8, buf: []u8) []const u8 {
    const hex = "0123456789abcdef";
    var pos: usize = 0;
    for (id) |b| {
        if (pos + 2 > buf.len) break;
        buf[pos + 0] = hex[b >> 4];
        buf[pos + 1] = hex[b & 0x0f];
        pos += 2;
    }
    return buf[0..pos];
}

fn rolesToString(roles: u32, buf: []u8) []const u8 {
    var pos: usize = 0;
    var first = true;
    inline for (.{
        .{ input.ROLE_POINTER, "pointer" },
        .{ input.ROLE_KEYBOARD, "keyboard" },
        .{ input.ROLE_TOUCH, "touch" },
        .{ input.ROLE_PEN, "pen" },
        .{ input.ROLE_LIGHTING, "lighting" },
    }) |entry| {
        const mask: u32 = entry[0];
        const label: []const u8 = entry[1];
        if ((roles & mask) != 0) {
            if (!first) {
                if (pos + 1 > buf.len) break;
                buf[pos] = ',';
                pos += 1;
            }
            for (label) |c| {
                if (pos + 1 > buf.len) break;
                buf[pos] = c;
                pos += 1;
            }
            first = false;
        }
    }
    if (pos == 0) {
        const none = "none";
        for (none) |c| {
            if (pos + 1 > buf.len) break;
            buf[pos] = c;
            pos += 1;
        }
    }
    return buf[0..pos];
}

fn sourceRoleName(role: u8) []const u8 {
    return switch (role) {
        input.SOURCE_POINTER => "pointer",
        input.SOURCE_KEYBOARD => "keyboard",
        input.SOURCE_TOUCH => "touch",
        input.SOURCE_PEN => "pen",
        input.SOURCE_LIGHTING => "lighting",
        input.SOURCE_DEVICE_LIFECYCLE => "lifecycle",
        else => "unknown",
    };
}

fn eventTypeName(role: u8, event_type: u8) []const u8 {
    return switch (role) {
        input.SOURCE_POINTER => switch (event_type) {
            1 => "motion",
            2 => "button_down",
            3 => "button_up",
            4 => "scroll",
            else => "unknown",
        },
        input.SOURCE_KEYBOARD => switch (event_type) {
            1 => "key_down",
            2 => "key_up",
            else => "unknown",
        },
        input.SOURCE_DEVICE_LIFECYCLE => switch (event_type) {
            1 => "attach",
            2 => "detach",
            else => "unknown",
        },
        else => "unknown",
    };
}

// ============================================================================
// JSON helpers
// ============================================================================
//
// We emit JSON manually rather than pulling in std.json for two reasons:
// (1) the schema is small and stable, and (2) we want guaranteed
// streaming output (one JSON object per line) for events --json,
// which std.json's high-level API does not give us cleanly.

fn jsonEscape(s: []const u8, buf: []u8) []const u8 {
    var pos: usize = 0;
    for (s) |c| {
        if (pos + 6 > buf.len) break; // worst case: \uXXXX
        switch (c) {
            '"' => {
                buf[pos] = '\\';
                buf[pos + 1] = '"';
                pos += 2;
            },
            '\\' => {
                buf[pos] = '\\';
                buf[pos + 1] = '\\';
                pos += 2;
            },
            '\n' => {
                buf[pos] = '\\';
                buf[pos + 1] = 'n';
                pos += 2;
            },
            '\r' => {
                buf[pos] = '\\';
                buf[pos + 1] = 'r';
                pos += 2;
            },
            '\t' => {
                buf[pos] = '\\';
                buf[pos + 1] = 't';
                pos += 2;
            },
            0x00...0x07, 0x0b, 0x0c, 0x0e...0x1f, 0x7f => {
                const hex = "0123456789abcdef";
                buf[pos] = '\\';
                buf[pos + 1] = 'u';
                buf[pos + 2] = '0';
                buf[pos + 3] = '0';
                buf[pos + 4] = hex[(c >> 4) & 0x0f];
                buf[pos + 5] = hex[c & 0x0f];
                pos += 6;
            },
            else => {
                buf[pos] = c;
                pos += 1;
            },
        }
    }
    return buf[0..pos];
}

// ============================================================================
// State subcommand
// ============================================================================

fn runState(opts: Options) !void {
    const reader = input.StateReader.init(input.STATE_PATH);
    defer reader.deinit();

    if (!reader.isValid()) {
        writeErr("inputdump: state region not valid at {s}\n", .{input.STATE_PATH});
        writeErr("  (file absent, wrong magic/version, or state_valid=0)\n", .{});
        writeErr("  load inputfs and attach at least one device, then retry.\n", .{});
        std.process.exit(1);
    }

    const initial = try reader.snapshot();
    if (opts.json) {
        printStateJson(initial, opts);
    } else {
        printStateHuman(initial, opts, "snapshot");
    }

    if (!opts.watch_changes) return;

    if (!opts.json) {
        writeOut("\nwatching (interval={d} ms; Ctrl-C to stop)\n", .{opts.interval_ms});
    }

    var prev = initial;
    while (true) {
        std.Thread.sleep(opts.interval_ms * std.time.ns_per_ms);
        const snap = try reader.snapshot();
        if (!stateChanged(prev, snap)) continue;
        if (opts.json) {
            printStateJson(snap, opts);
        } else {
            printStateHuman(snap, opts, "changed");
        }
        prev = snap;
    }
}

fn stateChanged(a: input.StateSnapshot, b: input.StateSnapshot) bool {
    return a.last_sequence != b.last_sequence or
        a.pointer_x != b.pointer_x or
        a.pointer_y != b.pointer_y or
        a.pointer_buttons != b.pointer_buttons or
        a.device_count != b.device_count or
        a.active_touch_count != b.active_touch_count;
}

fn printStateHuman(snap: input.StateSnapshot, opts: Options, label: []const u8) void {
    writeOut("=== {s} ===\n", .{label});
    writeOut("magic:      INST (0x{x})\n", .{input.STATE_MAGIC});
    writeOut("version:    {d}\n", .{input.STATE_VERSION});
    writeOut("last_seq:   {d}\n", .{snap.last_sequence});
    writeOut("boot_off:   {d} ns\n", .{snap.boot_wall_offset_ns});
    writeOut("pointer:    x={d} y={d} buttons=0x{x}\n", .{ snap.pointer_x, snap.pointer_y, snap.pointer_buttons });
    writeOut("dev_count:  {d}\n", .{snap.device_count});
    writeOut("touch_act:  {d}\n", .{snap.active_touch_count});

    var slot: usize = 0;
    while (slot < input.STATE_SLOT_COUNT) : (slot += 1) {
        const dev = snap.devices[slot];
        const populated = dev.roles != 0 or dev.usb_vendor != 0 or dev.usb_product != 0;
        if (!populated and !opts.all_slots) continue;

        var id_buf: [33]u8 = undefined;
        var role_buf: [64]u8 = undefined;
        const id_str = deviceIdHex(dev.device_id, &id_buf);
        const role_str = rolesToString(dev.roles, &role_buf);
        const name_str = nameToSlice(&dev.name);

        if (opts.verbose) {
            writeOut("  slot[{d}]:\n", .{slot});
            writeOut("    device_id:   {s}\n", .{id_str});
            writeOut("    vendor:      0x{x:0>4}\n", .{dev.usb_vendor});
            writeOut("    product:     0x{x:0>4}\n", .{dev.usb_product});
            writeOut("    roles:       {s}\n", .{role_str});
            writeOut("    name:        '{s}'\n", .{name_str});
        } else {
            writeOut("  slot[{d}]: vendor=0x{x:0>4} product=0x{x:0>4} roles={s} name='{s}'\n", .{
                slot, dev.usb_vendor, dev.usb_product, role_str, name_str,
            });
        }
    }
}

fn printStateJson(snap: input.StateSnapshot, opts: Options) void {
    writeOut("{{\"version\":{d},\"last_sequence\":{d},\"boot_wall_offset_ns\":{d}", .{
        input.STATE_VERSION, snap.last_sequence, snap.boot_wall_offset_ns,
    });
    writeOut(",\"pointer\":{{\"x\":{d},\"y\":{d},\"buttons\":{d}}}", .{
        snap.pointer_x, snap.pointer_y, snap.pointer_buttons,
    });
    writeOut(",\"device_count\":{d},\"active_touch_count\":{d}", .{
        snap.device_count, snap.active_touch_count,
    });
    writeOut(",\"devices\":[", .{});
    var slot: usize = 0;
    var first = true;
    while (slot < input.STATE_SLOT_COUNT) : (slot += 1) {
        const dev = snap.devices[slot];
        const populated = dev.roles != 0 or dev.usb_vendor != 0 or dev.usb_product != 0;
        if (!populated and !opts.all_slots) continue;
        if (!first) writeOut(",", .{});
        first = false;
        var id_buf: [33]u8 = undefined;
        var name_esc_buf: [256]u8 = undefined;
        const id_str = deviceIdHex(dev.device_id, &id_buf);
        const name_str = nameToSlice(&dev.name);
        const name_esc = jsonEscape(name_str, &name_esc_buf);
        writeOut("{{\"slot\":{d},\"device_id\":\"{s}\",\"vendor\":{d},\"product\":{d},\"roles\":{d},\"name\":\"{s}\"}}", .{
            slot, id_str, dev.usb_vendor, dev.usb_product, dev.roles, name_esc,
        });
    }
    writeOut("]}}\n", .{});
}

// ============================================================================
// Devices subcommand
// ============================================================================

fn runDevices(opts: Options) !void {
    const reader = input.StateReader.init(input.STATE_PATH);
    defer reader.deinit();

    if (!reader.isValid()) {
        writeErr("inputdump: state region not valid at {s}\n", .{input.STATE_PATH});
        std.process.exit(1);
    }

    const snap = try reader.snapshot();
    if (opts.json) {
        printDevicesJson(snap, opts);
    } else {
        printDevicesHuman(snap, opts);
    }
}

fn printDevicesHuman(snap: input.StateSnapshot, opts: Options) void {
    writeOut("device_count: {d}\n", .{snap.device_count});
    var slot: usize = 0;
    while (slot < input.STATE_SLOT_COUNT) : (slot += 1) {
        const dev = snap.devices[slot];
        const populated = dev.roles != 0 or dev.usb_vendor != 0 or dev.usb_product != 0;
        if (!populated and !opts.all_slots) continue;

        var id_buf: [33]u8 = undefined;
        var role_buf: [64]u8 = undefined;
        const id_str = deviceIdHex(dev.device_id, &id_buf);
        const role_str = rolesToString(dev.roles, &role_buf);
        const name_str = nameToSlice(&dev.name);

        if (opts.verbose) {
            writeOut("slot[{d}]:\n", .{slot});
            writeOut("  device_id:   {s}\n", .{id_str});
            writeOut("  vendor:      0x{x:0>4}\n", .{dev.usb_vendor});
            writeOut("  product:     0x{x:0>4}\n", .{dev.usb_product});
            writeOut("  roles:       {s}\n", .{role_str});
            writeOut("  name:        '{s}'\n", .{name_str});
        } else {
            writeOut("slot[{d}]: vendor=0x{x:0>4} product=0x{x:0>4} roles={s} name='{s}'\n", .{
                slot, dev.usb_vendor, dev.usb_product, role_str, name_str,
            });
        }
    }
}

fn printDevicesJson(snap: input.StateSnapshot, opts: Options) void {
    writeOut("{{\"device_count\":{d},\"devices\":[", .{snap.device_count});
    var slot: usize = 0;
    var first = true;
    while (slot < input.STATE_SLOT_COUNT) : (slot += 1) {
        const dev = snap.devices[slot];
        const populated = dev.roles != 0 or dev.usb_vendor != 0 or dev.usb_product != 0;
        if (!populated and !opts.all_slots) continue;
        if (!first) writeOut(",", .{});
        first = false;
        var id_buf: [33]u8 = undefined;
        var name_esc_buf: [256]u8 = undefined;
        const id_str = deviceIdHex(dev.device_id, &id_buf);
        const name_str = nameToSlice(&dev.name);
        const name_esc = jsonEscape(name_str, &name_esc_buf);
        writeOut("{{\"slot\":{d},\"device_id\":\"{s}\",\"vendor\":{d},\"product\":{d},\"roles\":{d},\"name\":\"{s}\"}}", .{
            slot, id_str, dev.usb_vendor, dev.usb_product, dev.roles, name_esc,
        });
    }
    writeOut("]}}\n", .{});
}

// ============================================================================
// Events subcommand
// ============================================================================

const EventStats = struct {
    total: u64 = 0,
    by_role: [8]u64 = .{0} ** 8,
    by_device: [32]u64 = .{0} ** 32,
    overruns: u64 = 0,
    started_at_ns: i128 = 0,

    fn record(self: *EventStats, ev: input.Event) void {
        self.total += 1;
        if (ev.source_role < self.by_role.len) {
            self.by_role[ev.source_role] += 1;
        }
        if (ev.device_slot < self.by_device.len) {
            self.by_device[ev.device_slot] += 1;
        }
    }

    fn print(self: *const EventStats) void {
        writeOut("\n=== stats ===\n", .{});
        writeOut("total events:  {d}\n", .{self.total});
        writeOut("ring overruns: {d}\n", .{self.overruns});

        const now_ns = std.time.nanoTimestamp();
        const elapsed_ns_signed = now_ns - self.started_at_ns;
        const elapsed_ns: u64 = if (elapsed_ns_signed < 0) 0 else @intCast(elapsed_ns_signed);
        const elapsed_ms = elapsed_ns / std.time.ns_per_ms;
        if (elapsed_ms > 0) {
            const per_sec = (self.total * 1000) / elapsed_ms;
            writeOut("elapsed:       {d} ms\n", .{elapsed_ms});
            writeOut("avg rate:      {d} ev/s\n", .{per_sec});
        }

        writeOut("by role:\n", .{});
        var r: usize = 1;
        while (r < self.by_role.len) : (r += 1) {
            if (self.by_role[r] == 0) continue;
            writeOut("  {s:<10} {d}\n", .{ sourceRoleName(@intCast(r)), self.by_role[r] });
        }

        writeOut("by device slot:\n", .{});
        var d: usize = 0;
        while (d < self.by_device.len) : (d += 1) {
            if (self.by_device[d] == 0) continue;
            writeOut("  slot[{d:>2}]   {d}\n", .{ d, self.by_device[d] });
        }
    }
};

fn runEvents(opts: Options) !void {
    var reader = input.EventRingReader.init(input.EVENTS_PATH);
    defer reader.deinit();

    if (!reader.isValid()) {
        writeErr("inputdump: events ring not valid at {s}\n", .{input.EVENTS_PATH});
        std.process.exit(1);
    }

    // Position the cursor.
    if (opts.from_seq) |seq| {
        if (seq == 0) {
            // "from 0" means "from earliest available". Setting
            // last_consumed to anything below earliest_seq triggers
            // overrun handling on the next drain, which repositions
            // to earliest_seq - 1 (which means "next read = earliest").
            reader.last_consumed = 0;
        } else {
            reader.last_consumed = seq - 1;
        }
    } else {
        // Default for events without --from-seq: drain everything
        // currently in the ring. last_consumed=0 already does this.
    }

    var stats: EventStats = .{};
    stats.started_at_ns = std.time.nanoTimestamp();
    var stats_last_print_ns: i128 = stats.started_at_ns;

    var buf: [256]input.Event = undefined;
    var produced_any = false;

    // Initial drain.
    const initial = try reader.drain(&buf);
    if (initial.overrun) stats.overruns += 1;
    for (buf[0..initial.events_consumed]) |ev| {
        if (acceptEvent(ev, opts)) {
            stats.record(ev);
            if (opts.json) {
                printEventJson(ev);
            } else {
                printEventHuman(ev, opts);
            }
            produced_any = true;
        }
    }

    if (!opts.watch_changes) {
        if (!produced_any and !opts.json) {
            writeOut("(no matching events)\n", .{});
        }
        if (opts.stats and !opts.json) stats.print();
        return;
    }

    if (!opts.json) {
        writeOut("\nwatching (interval={d} ms; Ctrl-C to stop)\n", .{opts.interval_ms});
    }

    while (true) {
        std.Thread.sleep(opts.interval_ms * std.time.ns_per_ms);
        const result = try reader.drain(&buf);
        if (result.overrun) {
            stats.overruns += 1;
            if (!opts.json) writeOut("(ring overrun)\n", .{});
        }
        for (buf[0..result.events_consumed]) |ev| {
            if (!acceptEvent(ev, opts)) continue;
            stats.record(ev);
            if (opts.json) {
                printEventJson(ev);
            } else {
                printEventHuman(ev, opts);
            }
        }

        // Periodic stats with --stats --watch.
        if (opts.stats and !opts.json) {
            const now_ns = std.time.nanoTimestamp();
            const since_print = now_ns - stats_last_print_ns;
            if (since_print >= 5 * std.time.ns_per_s) {
                stats.print();
                stats_last_print_ns = now_ns;
            }
        }
    }
}

fn acceptEvent(ev: input.Event, opts: Options) bool {
    if (!opts.role.matches(ev.source_role)) return false;
    if (opts.device) |d| {
        if (ev.device_slot != d) return false;
    }
    if (!opts.event_type.matches(ev.event_type)) return false;
    return true;
}

fn printEventHuman(ev: input.Event, opts: Options) void {
    const role_str = sourceRoleName(ev.source_role);
    const type_str = eventTypeName(ev.source_role, ev.event_type);

    if (opts.verbose) {
        writeOut("event seq={d}\n", .{ev.seq});
        writeOut("  ts_ordering: {d}\n", .{ev.ts_ordering});
        writeOut("  ts_sync:     {d}\n", .{ev.ts_sync});
        writeOut("  device_slot: {d}\n", .{ev.device_slot});
        writeOut("  role:        {s} ({d})\n", .{ role_str, ev.source_role });
        writeOut("  type:        {s} ({d})\n", .{ type_str, ev.event_type });
        writeOut("  flags:       0x{x}\n", .{ev.flags});
        writeOut("  payload:     ", .{});
        for (ev.payload, 0..) |b, i| {
            if (i != 0 and i % 8 == 0) writeOut(" ", .{});
            writeOut("{x:0>2}", .{b});
        }
        writeOut("\n", .{});
        printEventDecodedFields(ev, "  decoded:     ");
        return;
    }

    // Compact one-liner. Decoded fields per type.
    switch (ev.source_role) {
        input.SOURCE_POINTER => {
            const x = std.mem.readInt(i32, ev.payload[0..4], .little);
            const y = std.mem.readInt(i32, ev.payload[4..8], .little);
            switch (ev.event_type) {
                1 => {
                    const dx = std.mem.readInt(i32, ev.payload[8..12], .little);
                    const dy = std.mem.readInt(i32, ev.payload[12..16], .little);
                    const buttons = std.mem.readInt(u32, ev.payload[16..20], .little);
                    const session_id = std.mem.readInt(u32, ev.payload[20..24], .little);
                    writeOut("seq={d} ts={d} dev={d} pointer.motion x={d} y={d} dx={d} dy={d} buttons=0x{x} session=0x{x}\n", .{
                        ev.seq, ev.ts_ordering, ev.device_slot, x, y, dx, dy, buttons, session_id,
                    });
                },
                2, 3 => {
                    const button = std.mem.readInt(u32, ev.payload[8..12], .little);
                    const buttons = std.mem.readInt(u32, ev.payload[12..16], .little);
                    const session_id = std.mem.readInt(u32, ev.payload[16..20], .little);
                    writeOut("seq={d} ts={d} dev={d} pointer.{s} x={d} y={d} button=0x{x} buttons=0x{x} session=0x{x}\n", .{
                        ev.seq, ev.ts_ordering, ev.device_slot, type_str, x, y, button, buttons, session_id,
                    });
                },
                4 => {
                    const scroll_dx = std.mem.readInt(i32, ev.payload[8..12], .little);
                    const scroll_dy = std.mem.readInt(i32, ev.payload[12..16], .little);
                    const delta_unit = std.mem.readInt(u32, ev.payload[16..20], .little);
                    const session_id = std.mem.readInt(u32, ev.payload[20..24], .little);
                    const unit_str: []const u8 = if (delta_unit == 0) "lines" else if (delta_unit == 1) "pixels" else "unknown";
                    writeOut("seq={d} ts={d} dev={d} pointer.scroll x={d} y={d} dx={d} dy={d} unit={s} session=0x{x}\n", .{
                        ev.seq, ev.ts_ordering, ev.device_slot, x, y, scroll_dx, scroll_dy, unit_str, session_id,
                    });
                },
                else => {
                    writeOut("seq={d} ts={d} dev={d} pointer.type{d} (unknown payload)\n", .{
                        ev.seq, ev.ts_ordering, ev.device_slot, ev.event_type,
                    });
                },
            }
        },
        input.SOURCE_KEYBOARD => switch (ev.event_type) {
            1, 2 => {
                const hid_usage = std.mem.readInt(u32, ev.payload[0..4], .little);
                const positional = std.mem.readInt(u32, ev.payload[4..8], .little);
                const modifiers = std.mem.readInt(u32, ev.payload[8..12], .little);
                const session_id = std.mem.readInt(u32, ev.payload[12..16], .little);
                writeOut("seq={d} ts={d} dev={d} keyboard.{s} hid_usage=0x{x} positional=0x{x} modifiers=0x{x} session=0x{x}\n", .{
                    ev.seq, ev.ts_ordering, ev.device_slot, type_str, hid_usage, positional, modifiers, session_id,
                });
            },
            else => {
                writeOut("seq={d} ts={d} dev={d} keyboard.type{d} (unknown payload)\n", .{
                    ev.seq, ev.ts_ordering, ev.device_slot, ev.event_type,
                });
            },
        },
        input.SOURCE_DEVICE_LIFECYCLE => switch (ev.event_type) {
            1 => {
                const roles = std.mem.readInt(u32, ev.payload[0..4], .little);
                writeOut("seq={d} ts={d} dev={d} lifecycle.attach roles=0x{x}\n", .{
                    ev.seq, ev.ts_ordering, ev.device_slot, roles,
                });
            },
            2 => {
                writeOut("seq={d} ts={d} dev={d} lifecycle.detach\n", .{
                    ev.seq, ev.ts_ordering, ev.device_slot,
                });
            },
            else => {
                writeOut("seq={d} ts={d} dev={d} lifecycle.type{d}\n", .{
                    ev.seq, ev.ts_ordering, ev.device_slot, ev.event_type,
                });
            },
        },
        else => {
            writeOut("seq={d} ts={d} dev={d} {s}.type{d}\n", .{
                ev.seq, ev.ts_ordering, ev.device_slot, role_str, ev.event_type,
            });
        },
    }
}

fn printEventDecodedFields(ev: input.Event, prefix: []const u8) void {
    switch (ev.source_role) {
        input.SOURCE_POINTER => {
            const x = std.mem.readInt(i32, ev.payload[0..4], .little);
            const y = std.mem.readInt(i32, ev.payload[4..8], .little);
            switch (ev.event_type) {
                1 => {
                    const dx = std.mem.readInt(i32, ev.payload[8..12], .little);
                    const dy = std.mem.readInt(i32, ev.payload[12..16], .little);
                    const buttons = std.mem.readInt(u32, ev.payload[16..20], .little);
                    const session_id = std.mem.readInt(u32, ev.payload[20..24], .little);
                    writeOut("{s}x={d} y={d} dx={d} dy={d} buttons=0x{x} session=0x{x}\n", .{ prefix, x, y, dx, dy, buttons, session_id });
                },
                2, 3 => {
                    const button = std.mem.readInt(u32, ev.payload[8..12], .little);
                    const buttons = std.mem.readInt(u32, ev.payload[12..16], .little);
                    const session_id = std.mem.readInt(u32, ev.payload[16..20], .little);
                    writeOut("{s}x={d} y={d} button=0x{x} buttons=0x{x} session=0x{x}\n", .{ prefix, x, y, button, buttons, session_id });
                },
                4 => {
                    const scroll_dx = std.mem.readInt(i32, ev.payload[8..12], .little);
                    const scroll_dy = std.mem.readInt(i32, ev.payload[12..16], .little);
                    const delta_unit = std.mem.readInt(u32, ev.payload[16..20], .little);
                    const session_id = std.mem.readInt(u32, ev.payload[20..24], .little);
                    const unit_str: []const u8 = if (delta_unit == 0) "lines" else if (delta_unit == 1) "pixels" else "unknown";
                    writeOut("{s}x={d} y={d} dx={d} dy={d} unit={s} session=0x{x}\n", .{ prefix, x, y, scroll_dx, scroll_dy, unit_str, session_id });
                },
                else => writeOut("{s}(no decoder)\n", .{prefix}),
            }
        },
        input.SOURCE_KEYBOARD => switch (ev.event_type) {
            1, 2 => {
                const hid_usage = std.mem.readInt(u32, ev.payload[0..4], .little);
                const positional = std.mem.readInt(u32, ev.payload[4..8], .little);
                const modifiers = std.mem.readInt(u32, ev.payload[8..12], .little);
                const session_id = std.mem.readInt(u32, ev.payload[12..16], .little);
                writeOut("{s}hid_usage=0x{x} positional=0x{x} modifiers=0x{x} session=0x{x}\n", .{ prefix, hid_usage, positional, modifiers, session_id });
            },
            else => writeOut("{s}(no decoder)\n", .{prefix}),
        },
        input.SOURCE_DEVICE_LIFECYCLE => switch (ev.event_type) {
            1 => {
                const roles = std.mem.readInt(u32, ev.payload[0..4], .little);
                writeOut("{s}roles=0x{x}\n", .{ prefix, roles });
            },
            2 => writeOut("{s}(no payload)\n", .{prefix}),
            else => writeOut("{s}(no decoder)\n", .{prefix}),
        },
        else => writeOut("{s}(no decoder)\n", .{prefix}),
    }
}

fn printEventJson(ev: input.Event) void {
    const role_str = sourceRoleName(ev.source_role);
    const type_str = eventTypeName(ev.source_role, ev.event_type);

    writeOut("{{\"seq\":{d},\"ts_ordering\":{d},\"ts_sync\":{d},\"device_slot\":{d}", .{
        ev.seq, ev.ts_ordering, ev.ts_sync, ev.device_slot,
    });
    writeOut(",\"role\":\"{s}\",\"role_id\":{d},\"type\":\"{s}\",\"type_id\":{d},\"flags\":{d}", .{
        role_str, ev.source_role, type_str, ev.event_type, ev.flags,
    });

    // Decoded payload fields per (role, type).
    switch (ev.source_role) {
        input.SOURCE_POINTER => {
            const x = std.mem.readInt(i32, ev.payload[0..4], .little);
            const y = std.mem.readInt(i32, ev.payload[4..8], .little);
            switch (ev.event_type) {
                1 => {
                    const dx = std.mem.readInt(i32, ev.payload[8..12], .little);
                    const dy = std.mem.readInt(i32, ev.payload[12..16], .little);
                    const buttons = std.mem.readInt(u32, ev.payload[16..20], .little);
                    const session_id = std.mem.readInt(u32, ev.payload[20..24], .little);
                    writeOut(",\"x\":{d},\"y\":{d},\"dx\":{d},\"dy\":{d},\"buttons\":{d},\"session_id\":{d}", .{ x, y, dx, dy, buttons, session_id });
                },
                2, 3 => {
                    const button = std.mem.readInt(u32, ev.payload[8..12], .little);
                    const buttons = std.mem.readInt(u32, ev.payload[12..16], .little);
                    const session_id = std.mem.readInt(u32, ev.payload[16..20], .little);
                    writeOut(",\"x\":{d},\"y\":{d},\"button\":{d},\"buttons\":{d},\"session_id\":{d}", .{ x, y, button, buttons, session_id });
                },
                4 => {
                    const scroll_dx = std.mem.readInt(i32, ev.payload[8..12], .little);
                    const scroll_dy = std.mem.readInt(i32, ev.payload[12..16], .little);
                    const delta_unit = std.mem.readInt(u32, ev.payload[16..20], .little);
                    const session_id = std.mem.readInt(u32, ev.payload[20..24], .little);
                    writeOut(",\"x\":{d},\"y\":{d},\"dx\":{d},\"dy\":{d},\"delta_unit\":{d},\"session_id\":{d}", .{ x, y, scroll_dx, scroll_dy, delta_unit, session_id });
                },
                else => {},
            }
        },
        input.SOURCE_KEYBOARD => switch (ev.event_type) {
            1, 2 => {
                const hid_usage = std.mem.readInt(u32, ev.payload[0..4], .little);
                const positional = std.mem.readInt(u32, ev.payload[4..8], .little);
                const modifiers = std.mem.readInt(u32, ev.payload[8..12], .little);
                const session_id = std.mem.readInt(u32, ev.payload[12..16], .little);
                writeOut(",\"hid_usage\":{d},\"positional\":{d},\"modifiers\":{d},\"session_id\":{d}", .{ hid_usage, positional, modifiers, session_id });
            },
            else => {},
        },
        input.SOURCE_DEVICE_LIFECYCLE => switch (ev.event_type) {
            1 => {
                const roles = std.mem.readInt(u32, ev.payload[0..4], .little);
                writeOut(",\"roles\":{d}", .{roles});
            },
            else => {},
        },
        else => {},
    }
    writeOut("}}\n", .{});
}

// ============================================================================
// Watch subcommand: live tail of state + events
// ============================================================================
//
// The watch subcommand prints state changes interleaved with event
// stream entries. State changes are reported as a single line
// summary (no full re-dump) so the output stays compact.

fn runWatch(opts: Options) !void {
    const state_reader = input.StateReader.init(input.STATE_PATH);
    defer state_reader.deinit();

    if (!state_reader.isValid()) {
        writeErr("inputdump: state region not valid at {s}\n", .{input.STATE_PATH});
        std.process.exit(1);
    }

    var event_reader = input.EventRingReader.init(input.EVENTS_PATH);
    defer event_reader.deinit();

    if (!event_reader.isValid()) {
        writeErr("inputdump: events ring not valid at {s}\n", .{input.EVENTS_PATH});
        std.process.exit(1);
    }

    var prev_state = try state_reader.snapshot();
    if (!opts.json) {
        writeOut("=== watch ===\n", .{});
        writeOut("initial: dev_count={d} last_seq={d} pointer=({d},{d}) buttons=0x{x}\n", .{
            prev_state.device_count, prev_state.last_sequence,
            prev_state.pointer_x, prev_state.pointer_y, prev_state.pointer_buttons,
        });
        writeOut("\nstreaming (interval={d} ms; Ctrl-C to stop)\n", .{opts.interval_ms});
    }

    var buf: [256]input.Event = undefined;

    // Skip the existing event backlog: we want to start at the
    // current writer_seq so the watch output shows what happens
    // from now on, not historical events.
    event_reader.last_consumed = event_reader.writerSeq();

    while (true) {
        std.Thread.sleep(opts.interval_ms * std.time.ns_per_ms);

        // Drain new events.
        const result = try event_reader.drain(&buf);
        if (result.overrun and !opts.json) {
            writeOut("(ring overrun)\n", .{});
        }
        for (buf[0..result.events_consumed]) |ev| {
            if (!acceptEvent(ev, opts)) continue;
            if (opts.json) {
                printEventJson(ev);
            } else {
                printEventHuman(ev, opts);
            }
        }

        // Check for state changes (and report a summary if any).
        const snap = try state_reader.snapshot();
        if (stateChanged(prev_state, snap)) {
            if (opts.json) {
                printStateJson(snap, opts);
            } else {
                writeOut("[state] dev_count={d} last_seq={d} pointer=({d},{d}) buttons=0x{x}\n", .{
                    snap.device_count, snap.last_sequence,
                    snap.pointer_x, snap.pointer_y, snap.pointer_buttons,
                });
            }
            prev_state = snap;
        }
    }
}

// ============================================================================
// main
// ============================================================================

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const opts = parseArgs(args);

    switch (opts.sub) {
        .state => try runState(opts),
        .events => try runEvents(opts),
        .watch => try runWatch(opts),
        .devices => try runDevices(opts),
    }
}
