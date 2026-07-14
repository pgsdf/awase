// pgsd-sessiond/src/sysinfo.zig
//
// System info displayed on the Stage 5 login UI: hostname, real
// memory, actual/physical memory, network status.
//
// All three queries snapshot once at UI startup. Hostname and
// memory are stable; network state can change while the UI is up,
// but for a login screen, snapshot semantics are fine. Stage 5
// doesn't poll.
//
// FreeBSD-specific APIs:
//   - sysctlbyname(3) for hw.realmem and hw.physmem - FreeBSD libc.
//   - getifaddrs(3) - POSIX, available on FreeBSD and Linux.
//   - hostname: handled by std.posix.gethostname (avoids FreeBSD's
//     <ssp/unistd.h> fortify wrapper, which Zig's @cImport cannot
//     follow due to the __asm__-rename attribute on the underlying
//     symbol).
//
// References:
//   - sysctl(3) §CTL_HW: HW_REALMEM = firmware-reported total,
//     HW_PHYSMEM = kernel-counted usable bytes after BIOS holes.
//   - getifaddrs(3): walk linked list, filter IFF_LOOPBACK and
//     IFF_UP, return first AF_INET match.

const std = @import("std");

const c = @cImport({
    @cInclude("sys/types.h");
    @cInclude("sys/socket.h");
    @cInclude("sys/sysctl.h");
    @cInclude("netinet/in.h");
    @cInclude("arpa/inet.h");
    @cInclude("ifaddrs.h");
    @cInclude("string.h");
});

// net/if.h is intentionally not @cInclude'd: on FreeBSD it transitively pulls
// <sys/time.h>, whose bintime_shift inline trips a Zig 0.16 translate-c bug
// ("@bitCast must have a known result type"). Only two interface-flag bits are
// needed, declared here against the stable FreeBSD ABI.
const IFF_UP: c_uint = 0x1;
const IFF_LOOPBACK: c_uint = 0x8;

pub const Error = error{
    HostnameFailed,
    SysctlFailed,
    GetIfaddrsFailed,
    BufferTooSmall,
    OutOfMemory,
};

// =============================================================================
// Hostname
// =============================================================================
//
// std.posix.gethostname routes through Zig's own libc bindings rather
// than @cImport-ing <unistd.h>. This matters on FreeBSD: when fortify
// is active, <unistd.h> pulls in <ssp/unistd.h> which redirects
// gethostname() through a `__ssp_real_gethostname` indirection. The
// indirection relies on a compiler `__asm__("gethostname")` rename
// attribute that Zig's translate-c does not preserve, so @cImport
// produces an unresolved symbol at link time. std.posix.gethostname
// declares the symbol directly, bypassing the wrapper, and returns
// a properly-bounded slice of the buffer.
//
// HOST_NAME_MAX (255 on FreeBSD per POSIX.1-2001) is the right buffer
// size; std.posix.gethostname's signature requires exactly this.

pub fn hostname(allocator: std.mem.Allocator) Error![]u8 {
    var buf: [std.posix.HOST_NAME_MAX]u8 = undefined;
    const slice = std.posix.gethostname(&buf) catch return Error.HostnameFailed;
    return allocator.dupe(u8, slice) catch Error.OutOfMemory;
}

// =============================================================================
// Memory
// =============================================================================
//
// hw.realmem and hw.physmem are both u64 on amd64. The sysctlbyname
// signature is:
//   int sysctlbyname(const char *name, void *oldp, size_t *oldlenp,
//                    const void *newp, size_t newlen);
// We pass our u64 by address and size, no new value.

pub fn realMemBytes() Error!u64 {
    return querySysctlU64("hw.realmem");
}

pub fn physMemBytes() Error!u64 {
    return querySysctlU64("hw.physmem");
}

/// Live memory pressure, in bytes, from FreeBSD's own page categories.
///
/// This is TELEMETRY, not a system fact: unlike hw.realmem and hw.physmem
/// (installed memory, constant, read once), these change continuously and
/// must be resampled. See State.maybeRefreshMemory.
///
/// The three-way split is the point, and it is why "used vs total" is the
/// wrong model on FreeBSD. The kernel uses free RAM for cache
/// aggressively, so a healthy machine has very little genuinely free
/// memory, and a two-way bar would show it as nearly full when it is not
/// under pressure at all. Inactive pages are reclaimable on demand: they
/// are cache, not consumption.
///
///   used   = v_active_count + v_wire_count   (genuinely consumed)
///   cache  = v_inactive_count                (reclaimable)
///   free   = v_free_count                    (unallocated)
pub const MemStats = struct {
    used_bytes: u64,
    cache_bytes: u64,
    free_bytes: u64,
    total_bytes: u64,
};

pub fn memStats() Error!MemStats {
    // vm.stats.vm.* counters are pages, and they are u_int (32-bit), not
    // u64. Reading a 4-byte sysctl into an 8-byte buffer leaves the upper
    // half undefined, so this needs its own width.
    const page_size = try querySysctlU64("hw.pagesize");

    const active = try querySysctlU32("vm.stats.vm.v_active_count");
    const wired = try querySysctlU32("vm.stats.vm.v_wire_count");
    const inactive = try querySysctlU32("vm.stats.vm.v_inactive_count");
    const free = try querySysctlU32("vm.stats.vm.v_free_count");
    const total = try querySysctlU32("vm.stats.vm.v_page_count");

    return .{
        .used_bytes = (@as(u64, active) + @as(u64, wired)) * page_size,
        .cache_bytes = @as(u64, inactive) * page_size,
        .free_bytes = @as(u64, free) * page_size,
        .total_bytes = @as(u64, total) * page_size,
    };
}

fn querySysctlU32(name: []const u8) Error!u32 {
    var name_z: [64]u8 = undefined;
    if (name.len >= name_z.len) return Error.BufferTooSmall;
    @memcpy(name_z[0..name.len], name);
    name_z[name.len] = 0;

    var value: u32 = 0;
    var len: usize = @sizeOf(u32);
    const rc = c.sysctlbyname(
        @ptrCast(&name_z),
        @ptrCast(&value),
        &len,
        null,
        0,
    );
    if (rc != 0) return Error.SysctlFailed;
    if (len != @sizeOf(u32)) return Error.SysctlFailed;
    return value;
}

fn querySysctlU64(name: []const u8) Error!u64 {
    // sysctlbyname wants a NUL-terminated name. Names are short
    // (max ~32 chars in practice); stack buffer is fine.
    var name_z: [64]u8 = undefined;
    if (name.len >= name_z.len) return Error.BufferTooSmall;
    @memcpy(name_z[0..name.len], name);
    name_z[name.len] = 0;

    var value: u64 = 0;
    var len: usize = @sizeOf(u64);
    const rc = c.sysctlbyname(
        @ptrCast(&name_z),
        @ptrCast(&value),
        &len,
        null,
        0,
    );
    if (rc != 0) return Error.SysctlFailed;
    if (len != @sizeOf(u64)) return Error.SysctlFailed;
    return value;
}

// Format a byte count for the login UI. Per ADR-free design decision
// in 2026-05-15 session: use MB for anything < 100 GB (matches dmesg
// "real memory = ..." wording), GB above that. Integer math; no
// decimals.
pub fn formatMemMB(allocator: std.mem.Allocator, bytes: u64) ![]u8 {
    const mb: u64 = bytes / (1024 * 1024);
    if (mb < 100 * 1024) {
        return std.fmt.allocPrint(allocator, "{d} MB", .{mb});
    }
    const gb: u64 = bytes / (1024 * 1024 * 1024);
    return std.fmt.allocPrint(allocator, "{d} GB", .{gb});
}

// =============================================================================
// Network
// =============================================================================
//
// Walk getifaddrs(3), find the first non-loopback IPv4 interface that's
// up and has an address. Return "<ifname> <ipv4>" formatted, or null
// if none found (in which case the UI shows "no network" in dim color).

pub const NetworkInfo = struct {
    ifname: []u8, // owned
    ipv4: [16]u8, // dotted-quad, NUL-terminated within
    ipv4_len: u8,

    pub fn ipv4Slice(self: *const NetworkInfo) []const u8 {
        return self.ipv4[0..self.ipv4_len];
    }

    pub fn deinit(self: *NetworkInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.ifname);
    }
};

pub fn network(allocator: std.mem.Allocator) Error!?NetworkInfo {
    var head: ?*c.struct_ifaddrs = null;
    if (c.getifaddrs(&head) != 0) return Error.GetIfaddrsFailed;
    defer c.freeifaddrs(head);

    var cur: ?*c.struct_ifaddrs = head;
    while (cur) |ifa| : (cur = ifa.ifa_next) {
        // Skip entries without an address.
        const addr = ifa.ifa_addr orelse continue;
        // IPv4 only in v1. (IPv6 is broader-scope, harder to display.)
        if (addr.*.sa_family != c.AF_INET) continue;

        const flags = ifa.ifa_flags;
        // Must be UP.
        if ((flags & IFF_UP) == 0) continue;
        // Skip loopback (`lo0` etc.).
        if ((flags & IFF_LOOPBACK) != 0) continue;

        // Cast to sockaddr_in to get the address.
        const sin: *const c.struct_sockaddr_in = @ptrCast(@alignCast(addr));
        var ip_buf: [16]u8 = .{0} ** 16;
        const ip_cstr = c.inet_ntop(
            c.AF_INET,
            &sin.sin_addr,
            @ptrCast(&ip_buf),
            ip_buf.len,
        );
        if (ip_cstr == null) continue;
        const ip_len = std.mem.indexOfScalar(u8, &ip_buf, 0) orelse ip_buf.len;

        // ifa_name is NUL-terminated; copy as a Zig slice.
        const name_cstr: [*:0]const u8 = @ptrCast(ifa.ifa_name);
        const name = std.mem.span(name_cstr);
        const name_dup = allocator.dupe(u8, name) catch return Error.OutOfMemory;

        return NetworkInfo{
            .ifname = name_dup,
            .ipv4 = ip_buf,
            .ipv4_len = @intCast(ip_len),
        };
    }

    // No matching interface; not an error, just an empty result.
    return null;
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

// hostname / sysctl / getifaddrs all touch the live system. Unit
// tests run against the test machine's real state, so they assert
// only properties that hold on any FreeBSD/Linux/macOS host (which
// is where the bench tests will run anyway).

test "hostname returns a non-empty string" {
    const h = try hostname(testing.allocator);
    defer testing.allocator.free(h);
    try testing.expect(h.len > 0);
    try testing.expect(h.len < 256);
}

test "formatMemMB renders small sizes in MB" {
    const s = try formatMemMB(testing.allocator, 16 * 1024 * 1024 * 1024);
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("16384 MB", s);
}

test "formatMemMB switches to GB at 100 GB" {
    const s = try formatMemMB(testing.allocator, 200 * 1024 * 1024 * 1024);
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("200 GB", s);
}

test "formatMemMB handles a typical 8 GB box" {
    const s = try formatMemMB(testing.allocator, 8 * 1024 * 1024 * 1024);
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("8192 MB", s);
}
