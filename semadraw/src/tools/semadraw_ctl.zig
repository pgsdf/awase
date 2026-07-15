// semadraw-ctl: ADR 0021 bench prober for the privileged control
// socket, and the capture client (CAPTURE-DESIGN.md commit 4).
// Exercises the transport: connect, send one verb, print the reply;
// capture additionally carries the shared-memory descriptor and
// writes the composited frame to a PPM file. The ADR 0021 Section 10
// transport checks (a status round-trip as the session authority;
// rejection of an unauthorized peer) are driven with this tool.
//
// Usage: semadraw-ctl [--socket PATH]
//        status|blank|unblank|watch|capture-info|capture <path>
//        |configure <surface-id> <width> <height>|surfaces
// watch: hold the connection open and print every display_state
// notification as it arrives (ADR 0021 Section 8; the Section 10
// notification bench check), until EOF or interrupt.
// capture-info: print the frame metadata (the sizing probe).
// capture <path>: write the composited screen to <path> as PPM (P6).
// surfaces: list every surface with id, owner, uid, current size,
// pending and acknowledged config serials.
// configure: the D-12 stage 2 administrative front end: tell the
// compositor to assign the surface a configuration (ADR 0022
// section 5); prints the allocated config_serial. The presented
// geometry does not change until the client acknowledges (stage 3).
// Exit codes: 0 reply received, 1 usage, 2 connect failed (also the
// unauthorized-peer outcome: the daemon closes without a reply),
// 3 daemon replied ctl_error (code printed).
//
// The privileged/unprivileged split is CAPTURE-DESIGN.md's posture:
// semadrawd exposes the framebuffer and copies pixels; this tool owns
// filenames, serialization, and image formats. The daemon never
// learns what a filename is and never learns that PPM exists.

const std = @import("std");
const compat = @import("compat");
const posix = std.posix;
const control = @import("control");

fn fail(comptime fmt: []const u8, args: anytype, code: u8) noreturn {
    std.debug.print(fmt ++ "\n", args);
    std.process.exit(code);
}

// CMSG_* arithmetic for the descriptor-carrying send, matching
// FreeBSD's sys/socket.h macros on amd64 (_ALIGN rounds up to
// sizeof(long)). The receive side owns the same arithmetic in
// semadrawd.zig; each side of the wire keeps its own, per the
// raw-posix idiom established in the 0.16 migration.
fn cmsgAlign(len: usize) usize {
    return (len + @sizeOf(usize) - 1) & ~(@as(usize, @sizeOf(usize) - 1));
}

fn cmsgSpace(len: usize) usize {
    return cmsgAlign(@sizeOf(std.c.cmsghdr)) + cmsgAlign(len);
}

fn cmsgLen(len: usize) usize {
    return cmsgAlign(@sizeOf(std.c.cmsghdr)) + len;
}

/// Send one request frame: header plus its (tiny) payload.
fn sendFrame(sock: posix.fd_t, verb: control.CtlMsgType, payload: []const u8) void {
    std.debug.assert(payload.len <= control.MAX_CTL_PAYLOAD);
    var out: [control.CtlHeader.SIZE + control.MAX_CTL_PAYLOAD]u8 = undefined;
    (control.CtlHeader{ .msg_type = verb, .flags = 0, .length = @intCast(payload.len) }).serialize(out[0..control.CtlHeader.SIZE]);
    @memcpy(out[control.CtlHeader.SIZE..][0..payload.len], payload);
    const total = control.CtlHeader.SIZE + payload.len;
    var off: usize = 0;
    while (off < total) {
        const wn = posix.system.write(sock, out[off..].ptr, total - off);
        if (wn < 0) fail("semadraw-ctl: write failed", .{}, 2);
        off += @intCast(wn);
    }
}

/// Send a header-only request frame.
fn sendVerb(sock: posix.fd_t, verb: control.CtlMsgType) void {
    sendFrame(sock, verb, &.{});
}

/// Send the capture request frame with the shared-memory descriptor
/// as SCM_RIGHTS ancillary data, in one sendmsg so the descriptor
/// accompanies exactly this frame (the daemon's receive path stashes
/// it latest-wins; one descriptor per request frame is the contract).
fn sendCaptureWithFd(sock: posix.fd_t, shm_fd: posix.fd_t) void {
    var hdr_buf: [control.CtlHeader.SIZE]u8 = undefined;
    (control.CtlHeader{ .msg_type = .capture, .flags = 0, .length = 0 }).serialize(&hdr_buf);

    var iov = [1]posix.iovec_const{.{ .base = &hdr_buf, .len = hdr_buf.len }};
    var cmsg_buf: [cmsgSpace(@sizeOf(posix.fd_t))]u8 align(@alignOf(usize)) = undefined;
    @memset(&cmsg_buf, 0);
    const cmsg: *std.c.cmsghdr = @ptrCast(@alignCast(&cmsg_buf));
    cmsg.len = @intCast(cmsgLen(@sizeOf(posix.fd_t)));
    cmsg.level = posix.SOL.SOCKET;
    cmsg.type = posix.SCM.RIGHTS;
    const data = @as([*]u8, @ptrCast(&cmsg_buf)) + cmsgAlign(@sizeOf(std.c.cmsghdr));
    const fdp: *posix.fd_t = @ptrCast(@alignCast(data));
    fdp.* = shm_fd;

    var msg = posix.msghdr_const{
        .name = null,
        .namelen = 0,
        .iov = &iov,
        .iovlen = 1,
        .control = &cmsg_buf,
        .controllen = @intCast(cmsg_buf.len),
        .flags = 0,
    };
    const n = compat.posix.sendmsg(sock, &msg, 0) catch
        fail("semadraw-ctl: sendmsg failed", .{}, 2);
    if (n != hdr_buf.len) fail("semadraw-ctl: short sendmsg", .{}, 2);
}

const Reply = struct {
    hdr: control.CtlHeader,
    payload_len: usize,
};

/// Read one reply into `in`: header, then its (tiny) payload.
fn readOneReply(sock: posix.fd_t, in: *[control.CtlHeader.SIZE + control.MAX_CTL_PAYLOAD]u8) Reply {
    var got: usize = 0;
    while (got < control.CtlHeader.SIZE) {
        const rn = posix.read(sock, in[got..]) catch fail("semadraw-ctl: read failed", .{}, 2);
        if (rn == 0) fail("semadraw-ctl: connection closed without a reply (peer not authorized?)", .{}, 2);
        got += rn;
    }
    const hdr = control.CtlHeader.deserialize(in[0..control.CtlHeader.SIZE]) catch
        fail("semadraw-ctl: malformed reply header", .{}, 2);
    if (hdr.length > control.MAX_CTL_PAYLOAD) fail("semadraw-ctl: oversize reply", .{}, 2);
    const total = control.CtlHeader.SIZE + hdr.length;
    while (got < total) {
        const rn = posix.read(sock, in[got..]) catch fail("semadraw-ctl: read failed", .{}, 2);
        if (rn == 0) fail("semadraw-ctl: connection closed mid-reply", .{}, 2);
        got += rn;
    }
    return .{ .hdr = hdr, .payload_len = hdr.length };
}

fn failCtlError(payload: []const u8) noreturn {
    const e = control.CtlErrorPayload.deserialize(payload) catch
        fail("semadraw-ctl: malformed ctl_error", .{}, 2);
    const name = if (std.enums.fromInt(control.CtlError, e.code)) |code|
        @tagName(code)
    else
        "unknown";
    fail("error: {s} ({d})", .{ name, e.code }, 3);
}

/// Convert one captured frame to tightly-packed RGB triples for PPM.
/// Honors stride (which may exceed width * 4: capturing a padded
/// surface as if it were tight is the classic sheared-screenshot
/// bug), and the source byte order named by the reply's format:
/// bgra8 is B,G,R,X per pixel (drawfs XRGB8888; the fourth byte
/// carries no meaning), rgba8 is R,G,B,A. `out` must be exactly
/// width * height * 3 bytes.
fn convertToRgb(hdr: control.CaptureHeader, pixels: []const u8, out: []u8) !void {
    const w: usize = hdr.width;
    const h: usize = hdr.height;
    const stride: usize = hdr.stride;
    if (out.len != w * h * 3) return error.BadOutputSize;
    if (stride < w * 4) return error.StrideTooSmall;
    if (pixels.len < stride * h) return error.PixelsTooSmall;

    const bgrx = switch (hdr.format) {
        0 => false, // rgba8
        1 => true, // bgra8
        else => return error.UnsupportedFormat,
    };

    var y: usize = 0;
    while (y < h) : (y += 1) {
        const row = pixels[y * stride ..][0 .. w * 4];
        var x: usize = 0;
        while (x < w) : (x += 1) {
            const p = row[x * 4 ..][0..4];
            const o = out[(y * w + x) * 3 ..][0..3];
            if (bgrx) {
                o[0] = p[2];
                o[1] = p[1];
                o[2] = p[0];
            } else {
                o[0] = p[0];
                o[1] = p[1];
                o[2] = p[2];
            }
        }
    }
}

/// Create the anonymous shared-memory object the daemon fills.
/// SHM_ANON is shm_open(2)'s documented sentinel path, (char *)1;
/// the object is unnamed from birth, so there is no window in which
/// a named object exists to unlink (FreeBSD has no memfd_create).
fn createCaptureShm(size: u64) posix.fd_t {
    const anon: [*:0]const u8 = @ptrFromInt(1);
    const flags: posix.O = .{ .ACCMODE = .RDWR };
    const rc = posix.system.shm_open(anon, @bitCast(flags), 0);
    if (rc < 0) fail("semadraw-ctl: shm_open(SHM_ANON) failed", .{}, 2);
    const fd: posix.fd_t = @intCast(rc);
    if (posix.system.ftruncate(fd, @intCast(size)) != 0)
        fail("semadraw-ctl: ftruncate to {d} bytes failed", .{size}, 2);
    return fd;
}

fn closeFd(fd: posix.fd_t) void {
    _ = posix.system.close(fd);
}

/// The capture flow: probe for sizing, create and size the object,
/// send it with the request, honor the reply's authoritative
/// metadata, convert, write. A display change between probe and
/// capture surfaces as capture_buffer_too_small, so the flow
/// re-probes and retries a bounded number of times.
fn runCapture(gpa: std.mem.Allocator, sock: posix.fd_t, out_path: []const u8) noreturn {
    var in: [control.CtlHeader.SIZE + control.MAX_CTL_PAYLOAD]u8 = undefined;

    var attempts: u8 = 0;
    while (attempts < 3) : (attempts += 1) {
        // Sizing probe.
        sendVerb(sock, .capture_info);
        const probe = readOneReply(sock, &in);
        if (probe.hdr.msg_type == .ctl_error)
            failCtlError(in[control.CtlHeader.SIZE..][0..probe.payload_len]);
        if (probe.hdr.msg_type != .capture_reply)
            fail("semadraw-ctl: unexpected capture_info reply type", .{}, 2);
        const probe_hdr = control.CaptureHeader.deserialize(in[control.CtlHeader.SIZE..][0..probe.payload_len]) catch
            fail("semadraw-ctl: malformed capture_info reply", .{}, 2);
        const probe_needed: u64 = @as(u64, probe_hdr.stride) * @as(u64, probe_hdr.height);
        if (probe_needed == 0) fail("semadraw-ctl: probe reports an empty frame", .{}, 2);

        // The object, sized from the probe.
        const shm_fd = createCaptureShm(probe_needed);
        defer closeFd(shm_fd);

        // The capture. The daemon copies into the object and replies
        // with the authoritative metadata for what it actually copied.
        sendCaptureWithFd(sock, shm_fd);
        const reply = readOneReply(sock, &in);
        if (reply.hdr.msg_type == .ctl_error) {
            const e = control.CtlErrorPayload.deserialize(in[control.CtlHeader.SIZE..][0..reply.payload_len]) catch
                fail("semadraw-ctl: malformed ctl_error", .{}, 2);
            if (std.enums.fromInt(control.CtlError, e.code) == .capture_buffer_too_small) {
                // Display changed between probe and capture; re-probe.
                continue;
            }
            failCtlError(in[control.CtlHeader.SIZE..][0..reply.payload_len]);
        }
        if (reply.hdr.msg_type != .capture_reply)
            fail("semadraw-ctl: unexpected capture reply type", .{}, 2);
        const hdr = control.CaptureHeader.deserialize(in[control.CtlHeader.SIZE..][0..reply.payload_len]) catch
            fail("semadraw-ctl: malformed capture reply", .{}, 2);

        // The reply is authoritative; the object was checked by the
        // daemon to hold stride * height of it, which can only have
        // shrunk relative to the probe (growth failed above).
        const needed: u64 = @as(u64, hdr.stride) * @as(u64, hdr.height);
        if (needed == 0 or needed > probe_needed)
            fail("semadraw-ctl: capture reply inconsistent with probe", .{}, 2);

        const mapped = posix.mmap(
            null,
            @intCast(needed),
            .{ .READ = true },
            .{ .TYPE = .SHARED },
            shm_fd,
            0,
        ) catch fail("semadraw-ctl: mmap of the capture object failed", .{}, 2);
        defer posix.munmap(mapped);

        writePpm(gpa, out_path, hdr, mapped);
        std.debug.print("wrote {s}: {d}x{d}\n", .{ out_path, hdr.width, hdr.height });
        std.process.exit(0);
    }
    fail("semadraw-ctl: capture kept failing capture_buffer_too_small (display changing?)", .{}, 2);
}

/// PPM (P6) is the validation format by design: if the buffer read,
/// the stride handling, or the byte order is wrong, a wrong PPM is
/// VISIBLY wrong. PNG becomes a change to this one function, later.
fn writePpm(gpa: std.mem.Allocator, path: []const u8, hdr: control.CaptureHeader, pixels: []const u8) void {
    const rgb_len: usize = @as(usize, hdr.width) * @as(usize, hdr.height) * 3;
    const rgb = gpa.alloc(u8, rgb_len) catch fail("semadraw-ctl: out of memory", .{}, 2);
    defer gpa.free(rgb);
    convertToRgb(hdr, pixels, rgb) catch |err|
        fail("semadraw-ctl: conversion failed: {t}", .{err}, 2);

    var io_ctx = compat.io.open(gpa) catch fail("semadraw-ctl: io init failed", .{}, 2);
    defer io_ctx.deinit();
    const io = io_ctx.io();

    var f = blk: {
        if (std.fs.path.isAbsolute(path))
            break :blk compat.fs.createFileAbsolute(io, path, .{}) catch
                fail("semadraw-ctl: cannot create {s}", .{path}, 2);
        break :blk compat.fs.cwd(io).createFile(path, .{}) catch
            fail("semadraw-ctl: cannot create {s}", .{path}, 2);
    };
    defer f.close();

    var head_buf: [64]u8 = undefined;
    const head = std.fmt.bufPrint(&head_buf, "P6\n{d} {d}\n255\n", .{ hdr.width, hdr.height }) catch unreachable;
    f.writeAll(head) catch fail("semadraw-ctl: write to {s} failed", .{path}, 2);
    f.writeAll(rgb) catch fail("semadraw-ctl: write to {s} failed", .{path}, 2);
}

pub fn main(init: std.process.Init.Minimal) !void {
    const gpa = std.heap.page_allocator;
    var path: []const u8 = control.DEFAULT_CTL_SOCKET_PATH;
    var verb: ?control.CtlMsgType = null;
    var watch = false;
    var capture_path: ?[]const u8 = null;
    var configure_req: ?control.ConfigurePayload = null;

    const args_owned = try compat.args.alloc(gpa, init.args);
    defer args_owned.deinit(gpa);
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
        } else if (std.mem.eql(u8, a, "capture-info")) {
            verb = .capture_info;
        } else if (std.mem.eql(u8, a, "surfaces")) {
            verb = .list_surfaces;
        } else if (std.mem.eql(u8, a, "configure")) {
            verb = .configure;
            if (i + 3 >= args.len) fail("semadraw-ctl: configure requires <surface-id> <width> <height>", .{}, 1);
            configure_req = .{
                .surface_id = std.fmt.parseInt(u32, args[i + 1], 10) catch
                    fail("semadraw-ctl: surface-id must be an unsigned integer", .{}, 1),
                .logical_width = std.fmt.parseFloat(f32, args[i + 2]) catch
                    fail("semadraw-ctl: width must be a number", .{}, 1),
                .logical_height = std.fmt.parseFloat(f32, args[i + 3]) catch
                    fail("semadraw-ctl: height must be a number", .{}, 1),
            };
            i += 3;
        } else if (std.mem.eql(u8, a, "capture")) {
            verb = .capture;
            i += 1;
            if (i >= args.len) fail("semadraw-ctl: capture requires an output path", .{}, 1);
            capture_path = args[i];
        } else if (std.mem.eql(u8, a, "watch")) {
            watch = true;
        } else {
            fail("semadraw-ctl: unknown argument '{s}'", .{a}, 1);
        }
    }
    if (watch and verb != null) fail("semadraw-ctl: watch takes no verb", .{}, 1);
    if (!watch and verb == null) fail("usage: semadraw-ctl [--socket PATH] status|blank|unblank|watch|capture-info|capture <path>|configure <surface-id> <width> <height>|surfaces", .{}, 1);

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
    if (v == .capture) runCapture(gpa, fd, capture_path.?);

    if (v == .list_surfaces) {
        sendVerb(fd, v);
        var in: [control.CtlHeader.SIZE + control.MAX_CTL_PAYLOAD]u8 = undefined;
        const first = readOneReply(fd, &in);
        if (first.hdr.msg_type == .ctl_error)
            failCtlError(in[control.CtlHeader.SIZE..][0..first.payload_len]);
        if (first.hdr.msg_type != .surfaces_reply)
            fail("semadraw-ctl: unexpected surfaces reply type", .{}, 2);
        const head = control.SurfacesReplyPayload.deserialize(in[control.CtlHeader.SIZE..][0..first.payload_len]) catch
            fail("semadraw-ctl: malformed surfaces_reply", .{}, 2);
        std.debug.print("{d} surface(s)\n", .{head.count});
        var remaining = head.count;
        while (remaining > 0) : (remaining -= 1) {
            const r = readOneReply(fd, &in);
            if (r.hdr.msg_type != .surface_info)
                fail("semadraw-ctl: unexpected frame in surface listing", .{}, 2);
            const info = control.SurfaceInfoPayload.deserialize(in[control.CtlHeader.SIZE..][0..r.payload_len]) catch
                fail("semadraw-ctl: malformed surface_info", .{}, 2);
            std.debug.print("  id={d} owner={d} uid={d} size={d:.0}x{d:.0} pending_serial={d} acked_serial={d}\n", .{
                info.surface_id, info.owner,      info.owner_uid,
                info.logical_width,               info.logical_height,
                info.pending_serial,              info.acked_serial,
            });
        }
        std.process.exit(0);
    }

    if (configure_req) |req| {
        var cpl: [control.ConfigurePayload.SIZE]u8 = undefined;
        req.serialize(&cpl);
        sendFrame(fd, v, &cpl);
    } else {
        sendVerb(fd, v);
    }
    var in: [control.CtlHeader.SIZE + control.MAX_CTL_PAYLOAD]u8 = undefined;
    const reply = readOneReply(fd, &in);
    const payload = in[control.CtlHeader.SIZE..][0..reply.payload_len];

    switch (reply.hdr.msg_type) {
        .display_state => {
            const st = control.DisplayStatePayload.deserialize(payload) catch
                fail("semadraw-ctl: malformed display_state", .{}, 2);
            const name = if (std.enums.fromInt(control.DisplayAxis, st.axis)) |axis|
                @tagName(axis)
            else
                "unknown";
            std.debug.print("display: {s}\n", .{name});
        },
        .capture_reply => {
            const h = control.CaptureHeader.deserialize(payload) catch
                fail("semadraw-ctl: malformed capture_reply", .{}, 2);
            std.debug.print("frame: {d}x{d} stride={d} format={d}\n", .{ h.width, h.height, h.stride, h.format });
        },
        .configure_reply => {
            const r = control.ConfigureReplyPayload.deserialize(payload) catch
                fail("semadraw-ctl: malformed configure_reply", .{}, 2);
            std.debug.print("configure: serial={d}\n", .{r.config_serial});
        },
        .ctl_ack => std.debug.print("ok\n", .{}),
        .ctl_error => failCtlError(payload),
        else => fail("semadraw-ctl: unexpected reply type", .{}, 2),
    }
}

// The conversion is where capture bugs live (stride shear, byte
// order), and PPM-first exists so they are visible; these tests make
// them visible earlier still.

test "convertToRgb honors stride (no shear)" {
    // 2x2 frame, stride 12 (one padding pixel per row). Distinct
    // per-pixel values so a shear cannot pass.
    const hdr = control.CaptureHeader{ .width = 2, .height = 2, .stride = 12, .format = 1 };
    const px = [_]u8{
        10, 11, 12, 0, 20, 21, 22, 0, 0xEE, 0xEE, 0xEE, 0xEE,
        30, 31, 32, 0, 40, 41, 42, 0, 0xEE, 0xEE, 0xEE, 0xEE,
    };
    var out: [12]u8 = undefined;
    try convertToRgb(hdr, &px, &out);
    // bgra8: B,G,R,X -> R,G,B; padding bytes never appear.
    const want = [_]u8{ 12, 11, 10, 22, 21, 20, 32, 31, 30, 42, 41, 40 };
    try std.testing.expectEqualSlices(u8, &want, &out);
}

test "convertToRgb rejects a stride below width * 4" {
    const hdr = control.CaptureHeader{ .width = 2, .height = 1, .stride = 4, .format = 1 };
    const px = [_]u8{ 0, 0, 0, 0 };
    var out: [6]u8 = undefined;
    try std.testing.expectError(error.StrideTooSmall, convertToRgb(hdr, &px, &out));
}

test "convertToRgb rejects short pixels and unknown formats" {
    const hdr = control.CaptureHeader{ .width = 2, .height = 2, .stride = 8, .format = 1 };
    const short = [_]u8{0} ** 15;
    var out: [12]u8 = undefined;
    try std.testing.expectError(error.PixelsTooSmall, convertToRgb(hdr, &short, &out));

    const bad = control.CaptureHeader{ .width = 1, .height = 1, .stride = 4, .format = 9 };
    const px = [_]u8{ 1, 2, 3, 4 };
    var o3: [3]u8 = undefined;
    try std.testing.expectError(error.UnsupportedFormat, convertToRgb(bad, &px, &o3));
}

test "convertToRgb rgba8 passes channels through" {
    const hdr = control.CaptureHeader{ .width = 1, .height = 1, .stride = 4, .format = 0 };
    const px = [_]u8{ 1, 2, 3, 4 };
    var out: [3]u8 = undefined;
    try convertToRgb(hdr, &px, &out);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 1, 2, 3 }, &out);
}
