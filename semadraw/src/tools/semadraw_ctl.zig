// semadraw-ctl: ADR 0021 bench prober for the privileged control
// socket. Exercises the step-1 transport: connect, send one verb,
// print the reply. The ADR 0021 Section 10 transport checks (a
// status round-trip as the session authority; rejection of an
// unauthorized peer) are driven with this tool.
//
// Usage: semadraw-ctl [--socket PATH] status|blank|unblank|watch
// watch: hold the connection open and print every display_state
// notification as it arrives (ADR 0021 Section 8; the Section 10
// notification bench check), until EOF or interrupt.
// Exit codes: 0 reply received, 1 usage, 2 connect failed (also the
// unauthorized-peer outcome: the daemon closes without a reply),
// 3 daemon replied ctl_error (code printed).

const std = @import("std");
const compat = @import("compat");
const posix = std.posix;
const control = @import("control");

fn fail(comptime fmt: []const u8, args: anytype, code: u8) noreturn {
    std.debug.print(fmt ++ "\n", args);
    std.process.exit(code);
}

pub fn main(init: std.process.Init.Minimal) !void {
    var path: []const u8 = control.DEFAULT_CTL_SOCKET_PATH;
    var verb: ?control.CtlMsgType = null;
    var watch = false;

    const args_owned = try compat.args.alloc(std.heap.page_allocator, init.args);
    defer args_owned.deinit(std.heap.page_allocator);
    const args = args_owned.argv;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--socket")) {
            i += 1;
            if (i < args.len) path = args[i];
        } else if (std.mem.eql(u8, a, "status")) {
            verb = .status_query;
        } else if (std.mem.eql(u8, a, "blank")) {
            verb = .blank;
        } else if (std.mem.eql(u8, a, "unblank")) {
            verb = .unblank;
        } else if (std.mem.eql(u8, a, "watch")) {
            watch = true;
        } else {
            fail("semadraw-ctl: unknown argument '{s}'", .{a}, 1);
        }
    }
    if (watch and verb != null) fail("semadraw-ctl: watch takes no verb", .{}, 1);
    if (!watch and verb == null) fail("usage: semadraw-ctl [--socket PATH] status|blank|unblank|watch", .{}, 1);

    const fd = compat.posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0) catch
        fail("semadraw-ctl: socket() failed", .{}, 2);
    defer _ = posix.system.close(fd);
    var addr: posix.sockaddr.un = .{ .family = posix.AF.UNIX, .path = [_]u8{0} ** 104 };
    if (path.len >= addr.path.len) fail("semadraw-ctl: socket path too long", .{}, 1);
    @memcpy(addr.path[0..path.len], path);
    compat.posix.connect(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un)) catch
        fail("semadraw-ctl: cannot connect to {s} (daemon down, or peer not authorized)", .{path}, 2);

    if (watch) {
        std.debug.print("watching {s} for display_state notifications...\n", .{path});
        while (true) {
            var win: [control.CtlHeader.SIZE + control.MAX_CTL_PAYLOAD]u8 = undefined;
            var wgot: usize = 0;
            while (wgot < control.CtlHeader.SIZE) {
                const rn = posix.read(fd, win[wgot..]) catch fail("semadraw-ctl: read failed", .{}, 2);
                if (rn == 0) return; // daemon closed; clean exit
                wgot += rn;
            }
            const whdr = control.CtlHeader.deserialize(win[0..control.CtlHeader.SIZE]) catch
                fail("semadraw-ctl: malformed notification header", .{}, 2);
            if (whdr.length > control.MAX_CTL_PAYLOAD) fail("semadraw-ctl: oversize notification", .{}, 2);
            const wtotal = control.CtlHeader.SIZE + whdr.length;
            while (wgot < wtotal) {
                const rn = posix.read(fd, win[wgot..]) catch fail("semadraw-ctl: read failed", .{}, 2);
                if (rn == 0) fail("semadraw-ctl: connection closed mid-notification", .{}, 2);
                wgot += rn;
            }
            if (whdr.msg_type == .display_state) {
                const st = control.DisplayStatePayload.deserialize(win[control.CtlHeader.SIZE..wtotal]) catch
                    fail("semadraw-ctl: malformed display_state", .{}, 2);
                const name = if (std.enums.fromInt(control.DisplayAxis, st.axis)) |axis|
                    @tagName(axis)
                else
                    "unknown";
                std.debug.print("display: {s}\n", .{name});
            }
        }
    }

    const v = verb.?;
    var out: [control.CtlHeader.SIZE]u8 = undefined;
    (control.CtlHeader{ .msg_type = v, .flags = 0, .length = 0 }).serialize(&out);
    var off: usize = 0;
    while (off < out.len) {
        const wn = posix.system.write(fd, out[off..].ptr, out.len - off);
        if (wn < 0) fail("semadraw-ctl: write failed", .{}, 2);
        off += @intCast(wn);
    }

    // Read one reply: header, then its (tiny) payload.
    var in: [control.CtlHeader.SIZE + control.MAX_CTL_PAYLOAD]u8 = undefined;
    var got: usize = 0;
    while (got < control.CtlHeader.SIZE) {
        const rn = posix.read(fd, in[got..]) catch fail("semadraw-ctl: read failed", .{}, 2);
        if (rn == 0) fail("semadraw-ctl: connection closed without a reply (peer not authorized?)", .{}, 2);
        got += rn;
    }
    const hdr = control.CtlHeader.deserialize(in[0..control.CtlHeader.SIZE]) catch
        fail("semadraw-ctl: malformed reply header", .{}, 2);
    const total = control.CtlHeader.SIZE + hdr.length;
    if (hdr.length > control.MAX_CTL_PAYLOAD) fail("semadraw-ctl: oversize reply", .{}, 2);
    while (got < total) {
        const rn = posix.read(fd, in[got..]) catch fail("semadraw-ctl: read failed", .{}, 2);
        if (rn == 0) fail("semadraw-ctl: connection closed mid-reply", .{}, 2);
        got += rn;
    }
    const payload = in[control.CtlHeader.SIZE..total];

    switch (hdr.msg_type) {
        .display_state => {
            const st = control.DisplayStatePayload.deserialize(payload) catch
                fail("semadraw-ctl: malformed display_state", .{}, 2);
            const name = if (std.enums.fromInt(control.DisplayAxis, st.axis)) |axis|
                @tagName(axis)
            else
                "unknown";
            std.debug.print("display: {s}\n", .{name});
        },
        .ctl_ack => std.debug.print("ok\n", .{}),
        .ctl_error => {
            const e = control.CtlErrorPayload.deserialize(payload) catch
                fail("semadraw-ctl: malformed ctl_error", .{}, 2);
            const name = if (std.enums.fromInt(control.CtlError, e.code)) |code|
                @tagName(code)
            else
                "unknown";
            std.debug.print("error: {s} ({d})\n", .{ name, e.code });
            std.process.exit(3);
        },
        else => fail("semadraw-ctl: unexpected reply type", .{}, 2),
    }
}
