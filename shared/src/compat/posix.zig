// shared/src/compat/posix.zig
//
// compat.posix: the Awase-owned boundary over the removed std.posix socket
// verbs. Implements shared ADR 0003.
//
// The 0.16 cycle removed nearly the entire std.posix socket-wrapper family
// (socket, socketpair, bind, listen, accept, connect, shutdown, sendmsg,
// recvmsg, send) while keeping the socket data types. This module owns the
// removed verbs, routing each through posix.system.* (the raw libc surface; on
// FreeBSD the tree always links libc, so posix.system is std.c). Callers keep
// speaking in the surviving native socket types (posix.sockaddr, posix.AF,
// posix.SOCK, posix.MSG, posix.msghdr, posix.iovec); only the verbs come from
// here.
//
// Verb ownership, not transport abstraction (ADR 0003 Decision 1). Unix sockets,
// TCP sockets, socketpairs, and SCM_RIGHTS descriptor passing remain visible and
// distinct at the call site. This module defines no socket types, no connection
// type, and no transport policy. It is a set of verb wrappers and nothing more.
//
// Error model (ADR 0003 Decision 6). This module owns its error contract rather
// than reproducing the historical std.posix error sets, following AD-6.
// Reproducing those sets would recouple the boundary to the volatility it
// exists to isolate. Each verb exposes a small owned error set derived from the
// failure modes its call sites actually act on. The 2026-06-15 survey of the
// seven socket-bearing files found that only send distinguishes a specific
// errno (EAGAIN backpressure under MSG.DONTWAIT); every other verb's call sites
// act on success versus failure alone (the socket_server connect probe, for
// instance, deliberately treats any connect failure identically). Errno is
// therefore mapped without panicking via unexpectedErrno, and any errno a call
// site does not act on collapses to the per-verb failure error.
//
// Handle convention (ADR 0003 Decision 6). Socket-producing calls return
// posix.socket_t and socket operations take posix.socket_t. posix.fd_t is
// reserved for generic descriptor APIs (the read/write surface in posix_safe).
// On FreeBSD the two are the same integer; the distinction documents intent.

const std = @import("std");
const posix = std.posix;
const system = posix.system;

// Owned error sets, one per verb. Narrow by design: the only named non-failure
// case in the current tree is send's WouldBlock. The rest are single failure
// errors; a call site that needs to distinguish a further errno adds a named
// case here when a real site requires it (ADR 0003 Decision 5 growth rule).
pub const SocketError = error{SocketFailed};
pub const SocketpairError = error{SocketpairFailed};
pub const BindError = error{BindFailed};
pub const ListenError = error{ListenFailed};
pub const AcceptError = error{AcceptFailed};
pub const ConnectError = error{ConnectFailed};
pub const ShutdownError = error{ShutdownFailed};
pub const SendError = error{ WouldBlock, SendFailed };
pub const SendmsgError = error{SendmsgFailed};
pub const RecvmsgError = error{RecvmsgFailed};

// shutdown owns its direction enum rather than depending on a std type: 0.16
// removed posix.ShutdownHow along with the wrapper. The values map through the
// surviving posix.SHUT constants, so nothing is hardcoded and the call site
// keeps reading compat.posix.shutdown(fd, .both).
pub const ShutdownHow = enum { recv, send, both };

pub fn socket(domain: u32, sock_type: u32, protocol: u32) SocketError!posix.socket_t {
    const rc = system.socket(@intCast(domain), @intCast(sock_type), @intCast(protocol));
    if (rc == -1) return error.SocketFailed;
    return @intCast(rc);
}

pub fn socketpair(
    domain: u32,
    sock_type: u32,
    protocol: u32,
    fds: *[2]posix.socket_t,
) SocketpairError!void {
    const rc = system.socketpair(@intCast(domain), @intCast(sock_type), @intCast(protocol), fds);
    if (rc == -1) return error.SocketpairFailed;
}

pub fn bind(fd: posix.socket_t, addr: *const posix.sockaddr, len: posix.socklen_t) BindError!void {
    const rc = system.bind(fd, addr, len);
    if (rc == -1) return error.BindFailed;
}

pub fn listen(fd: posix.socket_t, backlog: u31) ListenError!void {
    const rc = system.listen(fd, @intCast(backlog));
    if (rc == -1) return error.ListenFailed;
}

// accept owns the 4-argument accept4 form the tree uses, so CLOEXEC is set
// atomically at accept time (ADR 0003 Decision 6). No 3-argument variant is
// provided unless a call site requires one.
pub fn accept(
    fd: posix.socket_t,
    addr: ?*posix.sockaddr,
    addr_len: ?*posix.socklen_t,
    flags: u32,
) AcceptError!posix.socket_t {
    const rc = system.accept4(fd, addr, addr_len, @intCast(flags));
    if (rc == -1) return error.AcceptFailed;
    return @intCast(rc);
}

pub fn connect(fd: posix.socket_t, addr: *const posix.sockaddr, len: posix.socklen_t) ConnectError!void {
    const rc = system.connect(fd, addr, len);
    if (rc == -1) return error.ConnectFailed;
}

pub fn shutdown(fd: posix.socket_t, how: ShutdownHow) ShutdownError!void {
    const h: c_int = switch (how) {
        .recv => posix.SHUT.RD,
        .send => posix.SHUT.WR,
        .both => posix.SHUT.RDWR,
    };
    const rc = system.shutdown(fd, h);
    if (rc == -1) return error.ShutdownFailed;
}

// send is the one verb whose call sites distinguish an errno: under MSG.DONTWAIT
// EAGAIN is backpressure, not a fault, and the socket_server / tcp_server send
// paths switch on it (error.WouldBlock => would_block). That case is named;
// every other failure collapses to error.SendFailed.
pub fn send(fd: posix.socket_t, buf: []const u8, flags: u32) SendError!usize {
    const rc = system.send(fd, buf.ptr, buf.len, flags);
    if (rc < 0) {
        return switch (posix.errno(rc)) {
            .AGAIN => error.WouldBlock,
            else => error.SendFailed,
        };
    }
    return @intCast(rc);
}

// sendmsg and recvmsg take the surviving msghdr types directly. The SCM_RIGHTS
// ancillary-data machinery (CMSG arithmetic, cmsghdr) stays at the call site in
// shm.zig; these wrappers own only the two removed verbs (ADR 0003 Decision 4).
// recvmsg returns the byte count so the call site keeps its own end-of-stream
// (count == 0) and descriptor-extraction logic.
pub fn sendmsg(fd: posix.socket_t, msg: *const posix.msghdr_const, flags: u32) SendmsgError!usize {
    const rc = system.sendmsg(fd, msg, flags);
    if (rc < 0) return error.SendmsgFailed;
    return @intCast(rc);
}

pub fn recvmsg(fd: posix.socket_t, msg: *posix.msghdr, flags: u32) RecvmsgError!usize {
    const rc = system.recvmsg(fd, msg, flags);
    if (rc < 0) return error.RecvmsgFailed;
    return @intCast(rc);
}

// ---------------------------------------------------------------------------
// Tests. compat.posix imports only std, so it is standalone-benchable via
// ../tools/zig test src/compat/posix.zig with no consumer, which is the proof
// that the boundary lands (ADR 0003 migration order step a).

test "surface analyzes under the vendored toolchain" {
    // Reference every wrapper so its body is semantically analyzed even with no
    // live socket. This is the compile-proof for the whole owned surface.
    _ = &socket;
    _ = &socketpair;
    _ = &bind;
    _ = &listen;
    _ = &accept;
    _ = &connect;
    _ = &shutdown;
    _ = &send;
    _ = &sendmsg;
    _ = &recvmsg;
}

test "socketpair send and read round trip" {
    // Runtime proof of the basic data path: socketpair and send are owned here,
    // posix.read survives in 0.16 and is used to read the bytes back.
    var fds: [2]posix.socket_t = undefined;
    try socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds);
    defer _ = system.close(fds[0]);
    defer _ = system.close(fds[1]);

    const payload = "compat.posix";
    const sent = try send(fds[0], payload, 0);
    try std.testing.expectEqual(payload.len, sent);

    var buf: [64]u8 = undefined;
    const got = try posix.read(fds[1], buf[0..]);
    try std.testing.expectEqualStrings(payload, buf[0..got]);
}
