// AD-31.2: privilege module for semadrawd.
//
// This module centralises privilege-related concerns:
//
//   - NOBODY_UID and NOBODY_GID sentinels for connections without
//     identifiable credentials (today, TCP connections per ADR 0006
//     §2; future-other-shapes as needed).
//
//   - getPeerCredentials(fd): wraps FreeBSD's getpeereid(3) to
//     extract the effective uid/gid of the peer on a connected
//     Unix-domain SOCK_STREAM socket. Used by ClientManager
//     immediately after accept(2) on the local listener.
//
//   - isPrivilegedUid(peer_uid, configured): AD-31.3 helper that
//     evaluates whether a peer matches the configured privileged
//     uid (typically `_pgsd_sessiond` per PGSD's deployment). The
//     configured value is null when no privileged uid is set, in
//     which case no client is privileged. See ADR 0006 §3.
//
// dropPrivileges() (AD-31.1) currently lives in semadrawd.zig. A
// future small refactor can relocate it into this module; that
// refactor is deliberately out of scope for AD-31.2 to keep the
// commit focused.

const std = @import("std");
const posix = std.posix;

// ============================================================================
// Sentinels
// ============================================================================

// nobody / nogroup on FreeBSD by /etc/passwd convention. Used as
// the peer_uid / peer_gid for connections whose credentials are not
// identifiable (TCP connections, per ADR 0006 §2). Any future
// uid-based decision treats these as the lowest-trust class:
// allowed to interact only with surfaces created on the same
// connection, never granted privileged status.
pub const NOBODY_UID: posix.uid_t = 65534;
pub const NOBODY_GID: posix.gid_t = 65534;

// ============================================================================
// Peer credentials
// ============================================================================

pub const PeerCredentials = struct {
    uid: posix.uid_t,
    gid: posix.gid_t,
};

pub const PeerCredentialsError = error{
    GetPeerEidFailed,
};

// FreeBSD getpeereid(3): int getpeereid(int s, uid_t *euid, gid_t *egid).
// Returns 0 on success, -1 on error with errno set. Implemented in
// terms of the LOCAL_PEERCRED unix(4) socket option.
//
// Neither std.posix nor std.c exposes this in Zig 0.15.2 (verified
// 2026-05-11 by direct grep against /usr/local/lib/zig/std/*.zig).
// We declare it as an extern fn and link against libc, which the
// binary already does.
extern "c" fn getpeereid(s: c_int, euid: *posix.uid_t, egid: *posix.gid_t) c_int;

// Get the effective uid/gid of the peer on a connected Unix-domain
// SOCK_STREAM socket. Per ADR 0006 §2:
//
//   - Failure is a connection-level error: caller should close the
//     fd without sending a reply.
//   - The result is set once at session-init time and does not
//     mutate over the session's lifetime.
//
// This function does not log on failure; the caller has the
// connection context to log a meaningful error.
pub fn getPeerCredentials(fd: posix.socket_t) PeerCredentialsError!PeerCredentials {
    var euid: posix.uid_t = 0;
    var egid: posix.gid_t = 0;
    const rc = getpeereid(fd, &euid, &egid);
    if (rc != 0) {
        return PeerCredentialsError.GetPeerEidFailed;
    }
    return .{ .uid = euid, .gid = egid };
}

// Read errno value at the point of a getpeereid failure. The caller
// can format this into a diagnostic. Useful only immediately after
// getPeerCredentials returns an error; errno is per-thread and may
// be overwritten by intervening libc calls.
pub fn lastErrno() c_int {
    return std.c._errno().*;
}

// ============================================================================
// Privileged-uid recognition (AD-31.3)
// ============================================================================

// Return whether peer_uid matches the daemon's configured privileged
// uid. The configured value is null when SEMADRAW_PRIVILEGED_UID is
// unset, in which case no client is privileged (the default and the
// most restrictive posture).
//
// Per ADR 0006 §3, the privileged client is recognised by uid match
// only, not by group membership. PGSD configures this uid to be the
// uid of `_pgsd_sessiond`, the login daemon. Other distributions
// built on Awase may choose a different uid or none at all.
//
// NOBODY_UID is never privileged: a TCP connection (which uses
// NOBODY_UID as a sentinel) cannot be the login daemon, and a
// misconfiguration that set SEMADRAW_PRIVILEGED_UID=65534 would not
// trip this function into granting TCP clients privileged status.
// The check is `peer_uid != NOBODY_UID and peer_uid == configured`.
pub fn isPrivilegedUid(peer_uid: posix.uid_t, configured: ?posix.uid_t) bool {
    if (peer_uid == NOBODY_UID) return false;
    const expected = configured orelse return false;
    return peer_uid == expected;
}

// ============================================================================
// Tests
// ============================================================================

test "isPrivilegedUid returns false when configured is null" {
    try std.testing.expect(!isPrivilegedUid(1001, null));
    try std.testing.expect(!isPrivilegedUid(0, null));
}

test "isPrivilegedUid returns true on exact match" {
    try std.testing.expect(isPrivilegedUid(1003, 1003));
}

test "isPrivilegedUid returns false on mismatch" {
    try std.testing.expect(!isPrivilegedUid(1001, 1003));
}

test "isPrivilegedUid never grants NOBODY_UID privileged status" {
    // Even if an operator misconfigured SEMADRAW_PRIVILEGED_UID to
    // the NOBODY sentinel value, TCP clients (which use NOBODY_UID)
    // must not be treated as privileged.
    try std.testing.expect(!isPrivilegedUid(NOBODY_UID, NOBODY_UID));
}
