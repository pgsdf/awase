// pgsd-sessiond/src/launch.zig
//
// Stage 3 privilege drop and session-leader exec path, refactored
// in stage 4 so session resolution is the caller's responsibility
// (handled by session_file.zig). This module now starts from a
// resolved Exec= value and runs only the launch sequence:
//
//   1. pam_setcred(ESTABLISH_CRED).
//   2. pam_open_session.
//   3. Acquire login_cap_t via login_getpwclass(pwd).
//   4. Create /var/run/pgsd/<uid>/ per ADR 0005: 0700, owned by user.
//   5. Build the session-leader environment per ADR 0005: clean slate,
//      PGSD/XDG/POSIX vars, plus PAM contributions from pam_getenvlist.
//   6. fork(2). Parent waits on the child; child becomes the session
//      leader's ancestor.
//   7. Child: setsid(2), replace environ with constructed env, run
//      setusercontext twice (pre-setuid flags, then LOGIN_SETUSER
//      per FreeBSD login(1) pattern), chdir($HOME or /tmp), execvp
//      the user's shell with -c <exec_value> per ADR 0004.
//   8. Parent: waitpid, pam_close_session, pam_setcred(DELETE_CRED).
//
// References:
//   - ADR 0001 §Launch sequence.
//   - ADR 0004 §Exec — execvp(shell, [shell, "-c", exec_value]).
//   - ADR 0005 §Runtime environment — env discipline and runtime dir.
//   - setusercontext(3), login_cap(3), login_getpwclass(3),
//     pam_open_session(3), pam_getenvlist(3).

const std = @import("std");
const pam = @import("pam.zig");
const user_enum = @import("user_enum.zig");
const idle = @import("idle.zig");
const compat = @import("compat");
const log = std.log.scoped(.launch);

// F-SESSION-1: kill every remaining descendant of the ended session.
// Escalation ladder HUP, TERM, KILL, with the kernel's reaper facility
// as the enumeration authority: PROC_REAP_KILL signals the whole
// descendant subtree in one syscall (no userland snapshot races; a
// fork between phases is still a descendant and still counted), and
// PROC_REAP_STATUS.rs_descendants is the terminal-state gate. Zombies
// reparented to us are drained with waitpid(-1, WNOHANG) so the count
// can reach zero. The greeter transition does not proceed past this
// function until the count is zero or the defined failure state is
// reached: descendants surviving SIGKILL are unkillable kernel-stuck
// processes, logged loudly as an F-SESSION-1 property violation, and
// login proceeds rather than wedging the console forever on them.
fn reapSessionRemnants() void {
    // Signal numbers from std.posix rather than the cImport: this
    // file's cImport deliberately includes few headers (see the
    // sys/stat.h note above), and the bench's native sys/wait.h does
    // not expose SIG* the way the cross-compile's bundled headers do,
    // which is exactly how the first build of this function failed on
    // metal while passing analysis off it.
    const phases = [_]struct { sig: c_int, grace_ms: u64 }{
        .{ .sig = std.posix.SIG.HUP, .grace_ms = 500 },
        .{ .sig = std.posix.SIG.TERM, .grace_ms = 2000 },
        .{ .sig = std.posix.SIG.KILL, .grace_ms = 5000 },
    };

    for (phases) |phase| {
        var st: c.struct_procctl_reaper_status = undefined;
        if (c.procctl(c.P_PID, 0, c.PROC_REAP_STATUS, &st) != 0) {
            log.warn("PROC_REAP_STATUS failed (errno {}); teardown blind, sending {} to subtree anyway", .{ errno(), phase.sig });
        } else if (st.rs_descendants == 0) {
            return; // terminal state: nothing survived
        }

        var rk: c.struct_procctl_reaper_kill = std.mem.zeroes(c.struct_procctl_reaper_kill);
        rk.rk_sig = phase.sig;
        rk.rk_flags = 0; // whole descendant subtree
        _ = c.procctl(c.P_PID, 0, c.PROC_REAP_KILL, &rk);

        // Grace: drain reparented zombies while polling the count.
        const POLL_MS: u64 = 100;
        var waited: u64 = 0;
        while (waited < phase.grace_ms) : (waited += POLL_MS) {
            var zst: c_int = 0;
            while (c.waitpid(-1, &zst, c.WNOHANG) > 0) {}
            var st2: c.struct_procctl_reaper_status = undefined;
            if (c.procctl(c.P_PID, 0, c.PROC_REAP_STATUS, &st2) == 0 and st2.rs_descendants == 0) {
                return;
            }
            compat.time.sleep(compat.time.Duration.fromNanoseconds(POLL_MS * std.time.ns_per_ms));
        }
    }

    var st: c.struct_procctl_reaper_status = undefined;
    if (c.procctl(c.P_PID, 0, c.PROC_REAP_STATUS, &st) == 0 and st.rs_descendants != 0) {
        log.err("F-SESSION-1 property violation: {} unkillable session descendants survive SIGKILL; proceeding to greeter", .{st.rs_descendants});
    }
}

const c = @cImport({
    @cInclude("sys/types.h");
    // sys/stat.h omitted: in combination it transitively pulls <sys/time.h>,
    // whose bintime_shift inline trips a Zig 0.16 translate-c bug. Only mkdir
    // and chmod are needed, routed to std.c below.
    @cInclude("sys/wait.h");
    @cInclude("sys/procctl.h"); // F-SESSION-1: reaper facility
    @cInclude("login_cap.h");
    @cInclude("pwd.h");
    @cInclude("unistd.h");
    @cInclude("stdlib.h");
    @cInclude("errno.h");
    @cInclude("string.h");
});

// =============================================================================
// Errors
// =============================================================================

pub const Error = error{
    // login.conf interaction
    LoginCapAcquireFailed, // login_getpwclass returned NULL
    // Runtime directory
    RuntimeDirCreateFailed, // mkdir/chown failed
    // Fork/exec
    ForkFailed,
    SetusercontextFailed,
    SetsidFailed,
    ExecFailed, // execvp returned (it shouldn't)
    // Misc
    OutOfMemory,
};

// =============================================================================
// Configuration constants per ADR 0005
// =============================================================================

// Runtime dir base. ADR 0005 §Runtime directory specifies this path
// shape; the per-uid subdir is created at launch time.
const RUNTIME_DIR_BASE: [:0]const u8 = "/var/run/pgsd";

// Fallback PATH when login.conf has no class for the user. ADR 0005
// §POSIX/FreeBSD specifies this exact string.
const FALLBACK_PATH: []const u8 =
    "/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin";

// =============================================================================
// Environment construction per ADR 0005
// =============================================================================
//
// Build the child's env from a clean slate. Order matters:
//
//   1. PGSD-specific (PGSD_SESSION_TYPE, PGSD_RUNTIME_DIR).
//   2. XDG-style (XDG_RUNTIME_DIR, XDG_SESSION_TYPE).
//   3. POSIX/FreeBSD standard (HOME, USER, LOGNAME, SHELL, PATH fallback).
//   4. (in child only, after fork) setusercontext applies login.conf
//      vars including PATH via setenv(3) — these mutate the child's
//      libc environ directly, AFTER we've installed our base env into
//      environ.
//   5. (in child only) PAM contributions appended via setenv(3),
//      with PAM taking precedence over what we set in steps 1-3.
//
// The env list returned here is the PRE-setusercontext base. PAM
// contributions are appended separately because they need to override
// our defaults but be overridden by setusercontext's class-specific
// settings... actually no: ADR 0005 §PAM contributions says PAM takes
// precedence if they overlap, so PAM is applied LAST. The fork-time
// order is therefore:
//
//   parent constructs base env (this function);
//   parent appends PAM env to base (also via this function);
//   child sets environ = base+pam;
//   child runs setusercontext (which may override via setenv).
//
// Wait — that conflicts with ADR 0005's stated precedence. Re-read:
// "PAM contributions take precedence if they overlap." This is
// regarding our defaults, not regarding login.conf. The intent
// is that pam_krb5's KRB5CCNAME should not be overridden by a
// login.conf-set KRB5CCNAME or by us. The order to honor this is:
//
//   1. base (us) → environ
//   2. setusercontext → environ (overrides our PATH etc.)
//   3. PAM → environ via explicit setenv (overrides setusercontext)
//
// This function returns just the base env (step 1). PAM application
// happens in the child after setusercontext.

const EnvEntry = struct {
    key: []const u8, // owned
    value: []const u8, // owned

    fn deinit(self: *EnvEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.key);
        allocator.free(self.value);
    }
};

pub const EnvList = struct {
    entries: std.ArrayListUnmanaged(EnvEntry) = .empty,

    pub fn deinit(self: *EnvList, allocator: std.mem.Allocator) void {
        for (self.entries.items) |*e| e.deinit(allocator);
        self.entries.deinit(allocator);
    }

    /// Append KEY=VALUE. KEY and VALUE are copied into the EnvList's
    /// allocator. Duplicate KEYs are not deduplicated by this method;
    /// callers control precedence by ordering their calls.
    pub fn put(
        self: *EnvList,
        allocator: std.mem.Allocator,
        key: []const u8,
        value: []const u8,
    ) !void {
        const k = try allocator.dupe(u8, key);
        errdefer allocator.free(k);
        const v = try allocator.dupe(u8, value);
        errdefer allocator.free(v);
        try self.entries.append(allocator, .{ .key = k, .value = v });
    }
};

/// Names that must NEVER appear in the session-leader env. See ADR 0005
/// §Environment variables filtered out. Used when filtering PAM
/// contributions and when assembling the final env in the child.
pub fn isFilteredEnvName(name: []const u8) bool {
    if (std.mem.startsWith(u8, name, "SUDO_")) return true;
    if (std.mem.startsWith(u8, name, "LD_")) return true;
    if (std.mem.eql(u8, name, "IFS")) return true;
    if (std.mem.eql(u8, name, "BASH_ENV")) return true;
    if (std.mem.eql(u8, name, "ENV")) return true;
    return false;
}

/// Build the pre-setusercontext base env per ADR 0005, populated from
/// the resolved user and the requested session type. PAM contributions
/// are NOT included here; they are applied in the child after
/// setusercontext.
pub fn buildBaseEnv(
    allocator: std.mem.Allocator,
    user: *const user_enum.EnumeratedUser,
    session_type: []const u8,
) !EnvList {
    var env = EnvList{};
    errdefer env.deinit(allocator);

    // Runtime dir path (used for both PGSD_RUNTIME_DIR and
    // XDG_RUNTIME_DIR).
    var rt_buf: [128]u8 = undefined;
    const rt_path = try std.fmt.bufPrint(&rt_buf, "{s}/{d}", .{ RUNTIME_DIR_BASE, user.uid });

    // PGSD-specific
    try env.put(allocator, "PGSD_SESSION_TYPE", session_type);
    try env.put(allocator, "PGSD_RUNTIME_DIR", rt_path);

    // XDG-style
    try env.put(allocator, "XDG_RUNTIME_DIR", rt_path);
    try env.put(allocator, "XDG_SESSION_TYPE", "pgsd");

    // POSIX / FreeBSD standard
    try env.put(allocator, "HOME", user.home);
    try env.put(allocator, "USER", user.name);
    try env.put(allocator, "LOGNAME", user.name);
    try env.put(allocator, "SHELL", user.shell);
    // PATH fallback; setusercontext will overwrite via setenv if the
    // user's class specifies path/setenv capabilities. If no class is
    // configured, the fallback wins.
    try env.put(allocator, "PATH", FALLBACK_PATH);

    return env;
}

// =============================================================================
// Runtime directory creation per ADR 0005
// =============================================================================
//
// Create /var/run/pgsd/<uid>/ with mode 0700, owned by uid:gid.
//
// Idempotent: if the directory already exists with correct ownership
// and mode, that's success. If it exists but with wrong ownership or
// mode (a previous-launch leftover or a malicious squat), reset it.
//
// We're running as root here so chown is permitted.

pub fn createRuntimeDir(uid: u32, gid: u32) Error!void {
    // Ensure the base /var/run/pgsd exists. ADR 0005 expects rc.d /
    // install.sh to create this; we mkdir it idempotently in case
    // /var/run is tmpfs (default on FreeBSD) and gets wiped at reboot
    // before the rc.d script ran.
    _ = std.c.mkdir(RUNTIME_DIR_BASE.ptr, 0o755);
    // ignore EEXIST and other errors; the per-uid mkdir below will
    // surface a real failure.

    var path_buf: [128]u8 = undefined;
    const path = std.fmt.bufPrintZ(
        &path_buf,
        "{s}/{d}",
        .{ RUNTIME_DIR_BASE, uid },
    ) catch return Error.RuntimeDirCreateFailed;

    if (std.c.mkdir(path.ptr, 0o700) != 0) {
        const err = errno();
        if (err != c.EEXIST) return Error.RuntimeDirCreateFailed;
    }

    // Even on EEXIST, force ownership and mode to the expected values.
    // chown is no-op when already correct; chmod likewise.
    if (c.chown(path.ptr, uid, gid) != 0) return Error.RuntimeDirCreateFailed;
    if (std.c.chmod(path.ptr, 0o700) != 0) return Error.RuntimeDirCreateFailed;
}

// =============================================================================
// Launch: the public entry point
// =============================================================================
//
// Prerequisites (caller's responsibility):
//   - Pam handle is started, authenticate() returned PAM_SUCCESS,
//     acctMgmt() returned PAM_SUCCESS.
//   - user has been resolved via user_enum.lookupByName.
//   - session_id and exec_value have been resolved via session_file.zig
//     (caller looks up the .session file and extracts both).
//   - The process is running as root (uid 0).
//
// session_id is the id used to populate PGSD_SESSION_TYPE in the
// session-leader env (ADR 0005); exec_value is the command string
// from the .session file's Exec= field (ADR 0004), passed verbatim
// to the user's shell as `shell -c exec_value`.
//
// On success: returns the session leader's exit code. The PAM session
// has been closed and credentials deleted. The caller should still
// call transaction.end() to tear down the PAM handle.
//
// On failure: returns an Error. The PAM session may or may not have
// been opened; the caller's defer transaction.end() handles cleanup.

pub fn launch(
    allocator: std.mem.Allocator,
    transaction: *pam.Pam,
    user: *const user_enum.EnumeratedUser,
    session_id: []const u8,
    exec_value: []const u8,
) Error!u8 {
    // 1. Establish credentials. Must happen after auth, before
    //    pam_open_session.
    transaction.setcred(pam.ESTABLISH_CRED) catch return mapPamError();
    errdefer transaction.setcred(pam.DELETE_CRED) catch {};

    // 2. Open the PAM session.
    transaction.openSession() catch return mapPamError();
    errdefer transaction.closeSession() catch {};

    // 3. Acquire login_cap_t. We don't free it in this scope because
    //    the child needs it post-fork; we free it in the parent after
    //    waitpid (or, if fork fails, before returning).
    const name_z = allocator.dupeZ(u8, user.name) catch return Error.OutOfMemory;
    defer allocator.free(name_z);
    const pwd_ptr = c.getpwnam(name_z.ptr);
    if (pwd_ptr == null) return Error.LoginCapAcquireFailed;
    const lc = c.login_getpwclass(pwd_ptr);
    if (lc == null) return Error.LoginCapAcquireFailed;
    defer c.login_close(lc);

    // 4. Create /var/run/pgsd/<uid>/.
    try createRuntimeDir(user.uid, user.gid);

    // 5. Build the base env. PAM contributions are NOT applied yet;
    //    they're a slice of "KEY=VALUE" strings we hand to the child.
    var base_env = buildBaseEnv(allocator, user, session_id) catch
        return Error.OutOfMemory;
    defer base_env.deinit(allocator);

    const pam_env = transaction.getEnvList(allocator) catch |err| switch (err) {
        error.OutOfMemory => return Error.OutOfMemory,
        else => return mapPamError(),
    };
    defer pam.Pam.freeEnvList(allocator, pam_env);

    // 7. Fork. The child path is below; the parent waits.
    // F-SESSION-1: acquire reaper status (procctl(2) PROC_REAP_ACQUIRE)
    // before forking, so every descendant of the session, including
    // double-forked daemons that escape the process-group hierarchy,
    // reparents to sessiond rather than init when orphaned. This is
    // what makes session-wide teardown at logout enumerable and
    // race-free: the kernel owns the descendant set, PROC_REAP_KILL
    // signals the whole subtree in one call, and PROC_REAP_STATUS
    // gives an authoritative count to gate the greeter transition on.
    // Idempotent across sessions (EBUSY when already the reaper).
    // Failure degrades teardown to leader-only, the pre-F-SESSION-1
    // behaviour, and is warned loudly because the greeter-exclusivity
    // property then rests on session processes exiting voluntarily.
    if (c.procctl(c.P_PID, 0, c.PROC_REAP_ACQUIRE, null) != 0) {
        if (errno() != c.EBUSY) {
            log.warn("PROC_REAP_ACQUIRE failed (errno {}); logout teardown degrades to leader-only", .{errno()});
        }
    }

    const pid = c.fork();
    if (pid < 0) return Error.ForkFailed;

    if (pid == 0) {
        // CHILD. Anything we do here that fails terminates the child
        // with a non-zero exit; we do NOT propagate errors back to the
        // parent (which is now a separate process). The parent learns
        // about failures via the child's exit code.
        childPath(
            lc,
            pwd_ptr.?,
            &base_env,
            pam_env,
            user.shell,
            exec_value,
            user.home,
        );
        // childPath does not return on success; if it returns, exec
        // failed. Exit with a sentinel code so the parent can tell
        // exec failed vs. session leader exited with that code.
        // Convention: 127 (command not found / exec failed), matching
        // shell behavior.
        c._exit(127);
    }

    // PARENT. Wait for the child to exit, running the SM-2 T0 idle
    // policy alongside (ADR 0021 Section 9(a); see idle.zig for the
    // folded-into-sessiond structural rationale). The blocking
    // waitpid becomes WNOHANG on a 1-second cadence so session exit
    // is still observed promptly, with the policy evaluated every
    // POLICY_EVERY passes (policy needs seconds-granularity at most:
    // T0 is minutes). The idle policy's connections are established
    // here in the parent AFTER the fork, so the session leader never
    // inherits them. A kqueue EVFILT_PROC + timer shape can replace
    // the cadence loop if the 1-second exit-detection latency ever
    // matters.
    var status: c_int = 0;
    var idle_policy = idle.IdlePolicy.init(allocator);
    defer idle_policy.deinit();
    const WAIT_TICK_NS: u64 = 1 * std.time.ns_per_s;
    // Shared with the login render loop (main.zig), so the two callers of
    // the policy cannot drift apart on rate.
    const POLICY_EVERY: u32 = idle.POLICY_EVERY;
    var passes: u32 = 0;
    while (true) {
        const w = c.waitpid(pid, &status, c.WNOHANG);
        if (w == pid) break;
        if (w < 0) {
            if (errno() == c.EINTR) continue;
            // waitpid failed for some other reason; treat as exec failed.
            break;
        }
        // w == 0: session leader still running.
        if (passes % POLICY_EVERY == 0) idle_policy.tick();
        passes +%= 1;
        compat.time.sleep(compat.time.Duration.fromNanoseconds(WAIT_TICK_NS));
    }

    // F-SESSION-1: session-wide teardown, BEFORE pam_close_session so
    // the PAM close hooks run while the session is still nominally
    // active (operator-ratified ordering). The security property this
    // enforces: after logout completes, no process of the previous
    // session may retain visible surfaces or input capability in the
    // greeter state. Found on metal: a background terminal survived
    // logout, reconnected, and overlaid half the login screen while
    // plausibly holding keyboard focus.
    reapSessionRemnants();

    // Tear down PAM session. The errdefer chain will not fire on the
    // happy path; we do this explicitly so we can fold the
    // pam_close_session / pam_setcred failures into the return value.
    transaction.closeSession() catch {};
    transaction.setcred(pam.DELETE_CRED) catch {};

    // Extract exit code from status. The W* macros in sys/wait.h are
    // not reliably translated by @cImport (they read like _WSTATUS(x) =
    // x & 0177, WIFEXITED = _WSTATUS == 0, WEXITSTATUS = x >> 8); we
    // implement them inline here against the documented FreeBSD bit
    // layout. WIFEXITED true → low-order 8 bits are exit code;
    // WIFSIGNALED true → return 128+signum per shell convention.
    const wstatus: c_int = status & 0o177;
    if (wstatus == 0) {
        // WIFEXITED.
        return @as(u8, @intCast((status >> 8) & 0xff));
    }
    if (wstatus != 0o177 and status != 0x13) {
        // WIFSIGNALED.
        const sig: u8 = @as(u8, @intCast(wstatus & 0x7f));
        return 128 +% sig;
    }
    return 1; // unknown exit (stopped/continued shouldn't happen with options=0)
}

// childPath runs in the forked child, as root initially. It performs
// the privilege drop, installs the env, sets up the session, and
// execs the shell. It does not return on success; if it returns, exec
// failed and the caller will _exit(127).
fn childPath(
    lc: ?*c.login_cap_t,
    pwd: *c.struct_passwd,
    base_env: *EnvList,
    pam_env: []const []u8,
    shell: []const u8,
    exec_value: []const u8,
    home: []const u8,
) void {
    // Step 1 (must be first): setsid. Create a new session and process
    // group so subsequent setlogin (via LOGIN_SETLOGIN in setusercontext)
    // affects only this child's session, not the parent's. The child
    // becomes the session leader of the new session.
    //
    // setsid fails (EPERM) if the caller is already a process group
    // leader. Right after fork, the child is normally a new process
    // group of one with no session, so setsid succeeds. We log-and-
    // continue on failure rather than abort, since some bench
    // configurations (running from a script that already setsid'd)
    // can put us in an awkward state.
    _ = c.setsid();

    // Step 2: Clear the inherited environ. We'll rebuild from scratch.
    //     `environ` is the libc global; clearenv(3) wipes it.
    if (c.clearenv() != 0) {
        return; // cannot proceed without a clean env
    }

    // Step 3: Install the base env via setenv(3). setenv mutates environ.
    //   setusercontext (step 4) will then add/override with login.conf
    //   class settings. PAM env (step 5) is applied last so it wins.
    for (base_env.entries.items) |entry| {
        // Bounded stack buffers; ADR 0004 caps Exec at 4096 bytes but
        // env values are typically short. 1024 each for key and value
        // is generous for the ADR 0005 base set; if any exceed, we
        // skip rather than truncate.
        var kbuf: [256]u8 = undefined;
        var vbuf: [1024]u8 = undefined;
        if (entry.key.len >= kbuf.len) continue;
        if (entry.value.len >= vbuf.len) continue;
        @memcpy(kbuf[0..entry.key.len], entry.key);
        kbuf[entry.key.len] = 0;
        @memcpy(vbuf[0..entry.value.len], entry.value);
        vbuf[entry.value.len] = 0;
        _ = c.setenv(@ptrCast(&kbuf), @ptrCast(&vbuf), 1);
    }

    // Step 4a: setusercontext pre-setuid flags. Per FreeBSD login(1)
    //   pattern with adaptation: we set login (since we now own a fresh
    //   session via setsid above), group, path, env, umask, resources,
    //   priority — everything that needs root or that should happen
    //   before the uid changes.
    const pre_flags: c_uint = @as(c_uint, c.LOGIN_SETGROUP) |
        @as(c_uint, c.LOGIN_SETLOGIN) |
        @as(c_uint, c.LOGIN_SETPATH) |
        @as(c_uint, c.LOGIN_SETENV) |
        @as(c_uint, c.LOGIN_SETUMASK) |
        @as(c_uint, c.LOGIN_SETRESOURCES) |
        @as(c_uint, c.LOGIN_SETPRIORITY);
    if (c.setusercontext(lc, pwd, pwd.*.pw_uid, pre_flags) != 0) {
        return;
    }

    // Step 4b: setusercontext LOGIN_SETUSER. Performs setuid internally.
    //   After this call we are running as the target user.
    if (c.setusercontext(lc, pwd, pwd.*.pw_uid, @as(c_uint, c.LOGIN_SETUSER)) != 0) {
        return;
    }

    // Step 5: After uid drop, apply PAM env contributions LAST so they
    //   take precedence over both our defaults and login.conf's
    //   LOGIN_SETENV additions. Each pam_env entry is "KEY=VALUE";
    //   split and setenv.
    for (pam_env) |entry| {
        const eq = std.mem.indexOfScalar(u8, entry, '=') orelse continue;
        const key = entry[0..eq];
        const value = entry[eq + 1 ..];
        if (isFilteredEnvName(key)) continue;
        var kbuf: [256]u8 = undefined;
        var vbuf: [4096]u8 = undefined;
        if (key.len >= kbuf.len) continue;
        if (value.len >= vbuf.len) continue;
        @memcpy(kbuf[0..key.len], key);
        kbuf[key.len] = 0;
        @memcpy(vbuf[0..value.len], value);
        vbuf[value.len] = 0;
        _ = c.setenv(@ptrCast(&kbuf), @ptrCast(&vbuf), 1);
    }

    // Step 6: chdir($HOME). Fall back to /tmp on failure per ADR 0005.
    var home_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (home.len < home_buf.len) {
        @memcpy(home_buf[0..home.len], home);
        home_buf[home.len] = 0;
        if (c.chdir(@ptrCast(&home_buf)) != 0) {
            _ = c.chdir("/tmp");
        }
    } else {
        _ = c.chdir("/tmp");
    }

    // Step 7: execvp the shell with -c <exec_value> per ADR 0004.
    //     argv: [shell, "-c", exec_value, NULL].
    var shell_z: [std.fs.max_path_bytes]u8 = undefined;
    if (shell.len >= shell_z.len) return;
    @memcpy(shell_z[0..shell.len], shell);
    shell_z[shell.len] = 0;

    // exec_value comes in as a Zig slice; copy to a NUL-terminated
    // stack buffer. ADR 0004 caps Exec at 4096; +1 for NUL.
    var exec_z: [4097]u8 = undefined;
    if (exec_value.len >= exec_z.len) return;
    @memcpy(exec_z[0..exec_value.len], exec_value);
    exec_z[exec_value.len] = 0;

    const dash_c = "-c";
    var argv: [4]?[*:0]const u8 = .{
        @ptrCast(&shell_z),
        @ptrCast(dash_c),
        @ptrCast(&exec_z),
        null,
    };

    _ = c.execvp(@ptrCast(&shell_z), @ptrCast(&argv));
    // execvp returns only on failure.
}

// =============================================================================
// Helpers
// =============================================================================

fn mapPamError() Error {
    // PAM errors during stage 3 launch path map to the launch-side
    // categories. The caller's PAM error reporting already happened
    // for authenticate/acctMgmt; setcred/open/close failures here are
    // less common and the main.zig reportAndExit path can't tell them
    // apart from the auth-phase failures anyway. Use ExecFailed as a
    // bucket: "the launch attempt did not produce a running session
    // leader." Future stages may grow finer-grained variants.
    return Error.ExecFailed;
}

// FreeBSD libc errno access. POSIX defines errno as a thread-local
// macro; the C-level expansion goes through __error() on FreeBSD.
fn errno() c_int {
    return c.__error().*;
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "isFilteredEnvName catches the documented set" {
    try testing.expect(isFilteredEnvName("SUDO_USER"));
    try testing.expect(isFilteredEnvName("SUDO_UID"));
    try testing.expect(isFilteredEnvName("LD_PRELOAD"));
    try testing.expect(isFilteredEnvName("LD_LIBRARY_PATH"));
    try testing.expect(isFilteredEnvName("IFS"));
    try testing.expect(isFilteredEnvName("BASH_ENV"));
    try testing.expect(isFilteredEnvName("ENV"));

    try testing.expect(!isFilteredEnvName("PATH"));
    try testing.expect(!isFilteredEnvName("HOME"));
    try testing.expect(!isFilteredEnvName("KRB5CCNAME"));
    try testing.expect(!isFilteredEnvName("SUDO")); // exact match, no underscore
}

test "EnvList put copies key and value" {
    var env = EnvList{};
    defer env.deinit(testing.allocator);

    try env.put(testing.allocator, "FOO", "bar");
    try env.put(testing.allocator, "BAZ", "qux");

    try testing.expectEqual(@as(usize, 2), env.entries.items.len);
    try testing.expectEqualStrings("FOO", env.entries.items[0].key);
    try testing.expectEqualStrings("bar", env.entries.items[0].value);
    try testing.expectEqualStrings("BAZ", env.entries.items[1].key);
    try testing.expectEqualStrings("qux", env.entries.items[1].value);
}

test "buildBaseEnv populates ADR 0005 standard variables" {
    var user = user_enum.EnumeratedUser{
        .name = "vic",
        .uid = 1001,
        .gid = 1001,
        .home = "/home/vic",
        .shell = "/bin/sh",
        .gecos = "",
        .attrs = .{},
    };

    var env = try buildBaseEnv(testing.allocator, &user, "default");
    defer env.deinit(testing.allocator);

    // Build a key→value lookup for assertions.
    var found_session: ?[]const u8 = null;
    var found_pgsd_rt: ?[]const u8 = null;
    var found_xdg_rt: ?[]const u8 = null;
    var found_xdg_type: ?[]const u8 = null;
    var found_home: ?[]const u8 = null;
    var found_user: ?[]const u8 = null;
    var found_logname: ?[]const u8 = null;
    var found_shell: ?[]const u8 = null;
    var found_path: ?[]const u8 = null;
    for (env.entries.items) |e| {
        if (std.mem.eql(u8, e.key, "PGSD_SESSION_TYPE")) found_session = e.value;
        if (std.mem.eql(u8, e.key, "PGSD_RUNTIME_DIR")) found_pgsd_rt = e.value;
        if (std.mem.eql(u8, e.key, "XDG_RUNTIME_DIR")) found_xdg_rt = e.value;
        if (std.mem.eql(u8, e.key, "XDG_SESSION_TYPE")) found_xdg_type = e.value;
        if (std.mem.eql(u8, e.key, "HOME")) found_home = e.value;
        if (std.mem.eql(u8, e.key, "USER")) found_user = e.value;
        if (std.mem.eql(u8, e.key, "LOGNAME")) found_logname = e.value;
        if (std.mem.eql(u8, e.key, "SHELL")) found_shell = e.value;
        if (std.mem.eql(u8, e.key, "PATH")) found_path = e.value;
    }

    try testing.expectEqualStrings("default", found_session.?);
    try testing.expectEqualStrings("/var/run/pgsd/1001", found_pgsd_rt.?);
    try testing.expectEqualStrings("/var/run/pgsd/1001", found_xdg_rt.?);
    try testing.expectEqualStrings("pgsd", found_xdg_type.?);
    try testing.expectEqualStrings("/home/vic", found_home.?);
    try testing.expectEqualStrings("vic", found_user.?);
    try testing.expectEqualStrings("vic", found_logname.?);
    try testing.expectEqualStrings("/bin/sh", found_shell.?);
    try testing.expectEqualStrings(FALLBACK_PATH, found_path.?);
}
