// pgsd-sessiond/src/main.zig
//
// Stages 1-8: PAM scaffolding CLI tool plus graphical login.
//
// This is NOT yet a daemon. It is a CLI tool with five mutually
// exclusive modes:
//
//   --auth-test --user <name>          (stage 1)
//       PAM authentication only. Prompts for password, runs
//       pam_authenticate + pam_acct_mgmt, reports outcome.
//
//   --list-users                       (stage 2)
//       Enumerates login-capable users with merged attribute-file
//       data per ADR 0003.
//
//   --launch --user <name> --session <name>      (stage 3+4)
//       Full login: PAM auth → resolve .session via the ADR 0004
//       parser → open session → drop privilege via setusercontext
//       → exec the session's Exec= line as the user. Must run as
//       root. Returns the session leader's exit code.
//
//   --list-sessions                    (stage 4)
//       Enumerates .session files in /usr/local/share/pgsd/sessions/
//       per ADR 0004. Lists valid sessions on stdout; malformed
//       files generate warnings on stderr.
//
//   --ui-only                          (stages 6 + 7 + 8)
//       Full graphical login with session looping and power
//       management. PAM auth via BufferedConv; session resolution
//       from a Stage 7 session-type picker (Tab opens a four-option
//       overlay with Terminal enabled and X11/Wayland/NDE visible-
//       but-disabled); fork+exec of the session leader as the
//       authenticated user; on session-leader exit, redisplay the
//       login UI rather than exiting the daemon (Stage 8). Ctrl-Q
//       opens a Stage 8 power menu offering Shutdown / Restart /
//       Suspend. Up to 3 password retries before the daemon
//       redisplays the login UI with a "too many attempts" message
//       (NOT a daemon exit; that would be a DoS vector). Must run
//       as root. Stage 9 will add daemon mode and boot integration.
//
// Stage 9 will add daemon mode and boot integration.
//
// See pgsd-sessiond/docs/adr/0001-design.md for the broader design,
// 0002-pam-stack.md for the PAM stack, 0003-attribute-file-format.md
// for the per-user attribute file, 0004-session-file-format.md for
// the .session file, 0005-runtime-environment.md for the env
// discipline, and 0007-bench-test-protocol.md for testing.

const std = @import("std");
const compat = @import("compat");
const posix = std.posix;
const pam = @import("pam.zig");
const user_enum = @import("user_enum.zig");
const launch_mod = @import("launch.zig");
const session_file = @import("session_file.zig");
const ui = @import("ui.zig");
const semadraw = @import("semadraw");

const c = @cImport({
    @cInclude("termios.h");
    @cInclude("unistd.h");
    @cInclude("stdlib.h"); // c.system() for Stage 8 power commands
});

// =============================================================================
// Exit codes. Stable across stages so bench scripts can rely on them.
// =============================================================================

const EXIT_OK: u8 = 0;
const EXIT_AUTH_FAIL: u8 = 1;
const EXIT_USER_UNKNOWN: u8 = 2;
const EXIT_ACCOUNT_INVALID: u8 = 3; // expired, locked, login.access deny
const EXIT_PAM_SERVICE: u8 = 4; // broken /etc/pam.d/ entry
const EXIT_MAX_TRIES: u8 = 5;
const EXIT_SESSION_NOT_FOUND: u8 = 6; // --launch: .session file missing
const EXIT_SESSION_INVALID: u8 = 7; // --launch: .session file malformed
const EXIT_LAUNCH_FAILED: u8 = 8; // --launch: fork/exec/setusercontext failed
const EXIT_USAGE: u8 = 10; // wrong CLI args
const EXIT_INTERNAL: u8 = 20; // OOM, unexpected error

// =============================================================================
// Signal handling (Stage 9: s6 supervision)
// =============================================================================
//
// Under s6 supervision, `service pgsd-sessiond stop` translates to
// `s6-svc -d`, which sends SIGTERM to the run-script's pid (which
// is pgsd-sessiond, since the run script `exec`s us). Without a
// handler, SIGTERM kills the process mid-render, leaving the
// surface in unknown state. The next time the service starts, the
// orphan surface on semadrawd may or may not be cleaned up by
// AD-31's disconnect-on-peer-uid-vanish path.
//
// Solution: a SIGTERM handler sets `shutdown_requested` to true.
// The inner and outer loops poll it and exit cleanly when set,
// running the same teardown path that an error would (destroy
// surface, disconnect, deinit state). The handler itself does
// the absolute minimum (an atomic store) because signal handlers
// run with restricted context.
//
// SIGINT is also handled the same way for Ctrl-C compatibility
// when running pgsd-sessiond from a shell during bench work.
//
// EXIT code on graceful shutdown is EXIT_OK; we want s6's
// flap-protection logic to see normal exits as normal, not as
// fast crashes (which would trigger the give-up threshold after
// 5 stops in 45 seconds).

var shutdown_requested = std.atomic.Value(bool).init(false);

fn signalHandler(_: posix.SIG) callconv(.c) void {
    shutdown_requested.store(true, .seq_cst);
}

fn installSignalHandlers() void {
    // std.posix.empty_sigset doesn't exist (it lives in std.os.linux,
    // not std.posix), so we zero-initialise the mask explicitly. An
    // all-zero sigset_t is the empty set on every POSIX target. This
    // is the same idiom semadrawd uses for its SIGPIPE handler
    // (semadraw/src/daemon/semadrawd.zig main()).
    const act = posix.Sigaction{
        .handler = .{ .handler = signalHandler },
        .mask = std.mem.zeroes(posix.sigset_t),
        .flags = 0,
    };
    // SIGTERM: the supervisor's stop signal.
    posix.sigaction(posix.SIG.TERM, &act, null);
    // SIGINT: for bench-from-shell Ctrl-C convenience.
    posix.sigaction(posix.SIG.INT, &act, null);
    // SIGHUP: also treat as graceful shutdown.
    posix.sigaction(posix.SIG.HUP, &act, null);
}

// =============================================================================
// Usage
// =============================================================================

const USAGE_TEXT =
    \\Usage: pgsd-sessiond <mode> [options]
    \\
    \\Modes (mutually exclusive, exactly one required):
    \\
    \\  --auth-test --user <username>
    \\      PAM authentication check (stage 1). Reads the user's
    \\      password from the controlling tty with echo suppressed,
    \\      runs pam_authenticate and pam_acct_mgmt against the
    \\      pgsd-sessiond PAM service (falling back to "login" if
    \\      /etc/pam.d/pgsd-sessiond is not installed yet), and
    \\      reports the outcome.
    \\
    \\  --list-users
    \\      Enumerate login-capable users (stage 2). Lists users
    \\      with UID > 1000 and a valid login shell, applying the
    \\      per-user attribute file at /etc/awase/users/<name>.conf
    \\      for display names, default sessions, and capabilities.
    \\
    \\  --list-sessions
    \\      Enumerate .session files (stage 4). Lists all valid
    \\      sessions in /usr/local/share/pgsd/sessions/ per ADR 0004.
    \\      Malformed files produce warnings on stderr; valid sessions
    \\      go to stdout.
    \\
    \\  --launch --user <username> --session <name>
    \\      Authenticate, then exec the named session leader as
    \\      the user (stage 3+4). Resolves the session from
    \\      /usr/local/share/pgsd/sessions/<name>.session via the
    \\      full ADR 0004 parser, opens the PAM session, creates
    \\      /var/run/pgsd/<uid>/, drops privilege to <username> via
    \\      setusercontext, and execs the user's shell with the
    \\      session file's Exec= line. Must be run as root. Returns
    \\      the session leader's exit code.
    \\
    \\  --ui-only
    \\      Full graphical login with session looping and power
    \\      management (stages 6 + 7 + 8). Connects to semadrawd,
    \\      sizes the surface to the framebuffer (queryOutputInfo),
    \\      draws the Identify/Password fields with sysinfo header,
    \\      captures keystrokes. On password submit, authenticates
    \\      via PAM (BufferedConv reads username/password directly
    \\      from memory; no TTY involved). On AUTH FAILURE: shows
    \\      "authentication failed; N attempts remaining" and
    \\      returns to the password field. After 3 failed attempts,
    \\      the login UI redisplays with a "too many failed
    \\      attempts" message; the daemon does NOT exit on auth
    \\      failure.
    \\
    \\      Console navigation (ADR 0011): a persistent left rail names
    \\      the views (Login, Session, Power) and the pane renders the
    \\      active one. Up from the login fields reaches the rail;
    \\      Up/Down move; Enter opens; ESC returns to the rail. Ctrl-S
    \\      jumps straight to Session and Ctrl-Q to Power from anywhere.
    \\
    \\      Session offers Terminal / X11 / Wayland / NDE; only Terminal
    \\      is enabled in v1 and the others render as "(not installed)".
    \\
    \\      Ctrl-S rather than Tab, because bare Tab is not currently
    \\      delivered to this daemon while Ctrl chords are (audit SA-5).
    \\
    \\      On AUTH SUCCESS: resolves the selected session type to
    \\      a .session file (Terminal -> default.session), tears
    \\      down the surface, and execs the session leader as the
    \\      user via launch_mod.launch. When the session leader
    \\      exits, the daemon redisplays the login UI (Stage 8
    \\      session loop, per ADR 0001 §Logout). If the session
    \\      exited suspiciously quickly (<2s) with a non-zero code,
    \\      the next login screen shows a "session exited quickly;
    \\      check configuration" hint (a clean logout is silent at any
    \\      duration; SM-5).
    \\
    \\      Stage 8 power menu: Ctrl-Q opens a centered overlay
    \\      with three options (Shutdown, Restart, Suspend). Up/Down
    \\      cycle; Enter selects; S/R/Z are accelerators. Shutdown
    \\      and Restart prompt for Y/N confirmation; Suspend acts
    \\      immediately. ESC cancels back to the prior field. The
    \\      daemon invokes "shutdown -p now", "shutdown -r now", or
    \\      "acpiconf -s 3" via system(3). Shutdown/Restart commit
    \\      the system to init's hands; the daemon is killed by
    \\      init's shutdown grace period. Suspend blocks until
    \\      resume, then returns to the login UI.
    \\
    \\      Must be run as root.
    \\
    \\Exit codes:
    \\  0   success
    \\  1   wrong password (--auth-test, --launch)
    \\  2   no such user (--auth-test, --launch)
    \\  3   account expired, locked, or access denied
    \\  4   PAM service configuration is broken
    \\  5   too many failed attempts
    \\  6   --launch: .session file not found
    \\  7   --launch: .session file malformed
    \\  8   --launch: privilege drop or exec failed
    \\  10  invalid arguments
    \\  20  internal error
    \\
;

fn printUsage(out: compat.fs.Stream) void {
    out.writeAll(USAGE_TEXT) catch {};
}

// =============================================================================
// Argument parsing. Strict; no positionals; fail loudly on unknowns.
// =============================================================================

const Args = struct {
    auth_test: bool = false,
    list_users: bool = false,
    list_sessions: bool = false,
    launch: bool = false,
    ui_only: bool = false,
    user: ?[]const u8 = null,
    session: ?[]const u8 = null,
};

const ArgError = error{
    MissingUserValue,
    MissingSessionValue,
    UnknownFlag,
    UnexpectedPositional,
    NoModeSelected,
    MultipleModesSelected,
    MissingUser,
    MissingSession,
};

// parseArgs is silent: it returns a specific error variant for each
// failure mode, and the caller decides how (and whether) to print.
// Keeping I/O out of the parser means tests can exercise the error
// paths without stderr noise polluting the test output.
//
// --help short-circuits with std.process.exit because help printing is
// inherently an I/O action; that's fine in a CLI tool's main path.
// Tests don't invoke parseArgs with --help.
fn parseArgs(argv: []const [:0]const u8) ArgError!Args {
    var args = Args{};
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "--auth-test")) {
            args.auth_test = true;
        } else if (std.mem.eql(u8, a, "--list-users")) {
            args.list_users = true;
        } else if (std.mem.eql(u8, a, "--list-sessions")) {
            args.list_sessions = true;
        } else if (std.mem.eql(u8, a, "--launch")) {
            args.launch = true;
        } else if (std.mem.eql(u8, a, "--ui-only")) {
            args.ui_only = true;
        } else if (std.mem.eql(u8, a, "--user")) {
            if (i + 1 >= argv.len) {
                return ArgError.MissingUserValue;
            }
            i += 1;
            args.user = argv[i];
        } else if (std.mem.startsWith(u8, a, "--user=")) {
            args.user = a["--user=".len..];
        } else if (std.mem.eql(u8, a, "--session")) {
            if (i + 1 >= argv.len) {
                return ArgError.MissingSessionValue;
            }
            i += 1;
            args.session = argv[i];
        } else if (std.mem.startsWith(u8, a, "--session=")) {
            args.session = a["--session=".len..];
        } else if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            printUsage(compat.fs.stdout());
            std.process.exit(EXIT_OK);
        } else if (std.mem.startsWith(u8, a, "-")) {
            return ArgError.UnknownFlag;
        } else {
            return ArgError.UnexpectedPositional;
        }
    }

    // Mode selection: exactly one of --auth-test, --list-users,
    // --list-sessions, --launch, --ui-only.
    const mode_count: u8 = @as(u8, @intFromBool(args.auth_test)) +
        @as(u8, @intFromBool(args.list_users)) +
        @as(u8, @intFromBool(args.list_sessions)) +
        @as(u8, @intFromBool(args.launch)) +
        @as(u8, @intFromBool(args.ui_only));
    if (mode_count == 0) return ArgError.NoModeSelected;
    if (mode_count > 1) return ArgError.MultipleModesSelected;

    // --user required for --auth-test and --launch.
    if (args.auth_test and args.user == null) return ArgError.MissingUser;
    if (args.launch and args.user == null) return ArgError.MissingUser;

    // --session required for --launch.
    if (args.launch and args.session == null) return ArgError.MissingSession;

    return args;
}

// printArgError shows a human-readable message for a parseArgs failure.
// Called from main(), never from tests. The argv slice is for showing
// the offending flag in UnknownFlag/UnexpectedPositional messages; pass
// the argv that caused the error.
fn printArgError(err: ArgError, argv: []const [:0]const u8) void {
    switch (err) {
        ArgError.MissingUserValue => {
            std.debug.print("ERROR: --user requires a value\n", .{});
        },
        ArgError.MissingSessionValue => {
            std.debug.print("ERROR: --session requires a value\n", .{});
        },
        ArgError.UnknownFlag => {
            // Find the offending flag for display. parseArgs returned at
            // the first unknown flag; we walk argv ourselves to find it.
            // (parseArgs could pass it back via a struct, but a specific
            // error type plus a one-time re-walk is simpler.)
            for (argv[1..]) |a| {
                if (std.mem.startsWith(u8, a, "-") and
                    !std.mem.eql(u8, a, "--auth-test") and
                    !std.mem.eql(u8, a, "--list-users") and
                    !std.mem.eql(u8, a, "--list-sessions") and
                    !std.mem.eql(u8, a, "--launch") and
                    !std.mem.eql(u8, a, "--ui-only") and
                    !std.mem.eql(u8, a, "--user") and
                    !std.mem.startsWith(u8, a, "--user=") and
                    !std.mem.eql(u8, a, "--session") and
                    !std.mem.startsWith(u8, a, "--session=") and
                    !std.mem.eql(u8, a, "--help") and
                    !std.mem.eql(u8, a, "-h"))
                {
                    std.debug.print("ERROR: unknown flag: {s}\n", .{a});
                    return;
                }
            }
            std.debug.print("ERROR: unknown flag (unable to identify)\n", .{});
        },
        ArgError.UnexpectedPositional => {
            for (argv[1..]) |a| {
                if (!std.mem.startsWith(u8, a, "-")) {
                    std.debug.print("ERROR: unexpected positional argument: {s}\n", .{a});
                    std.debug.print("       this tool only accepts flag arguments.\n", .{});
                    return;
                }
            }
            std.debug.print("ERROR: unexpected positional argument (unable to identify)\n", .{});
        },
        ArgError.NoModeSelected => {
            std.debug.print("ERROR: a mode flag is required: --auth-test, --list-users, --list-sessions, --launch, or --ui-only\n", .{});
        },
        ArgError.MultipleModesSelected => {
            std.debug.print("ERROR: --auth-test, --list-users, --list-sessions, --launch, and --ui-only are mutually exclusive\n", .{});
        },
        ArgError.MissingUser => {
            std.debug.print("ERROR: --user <username> is required for --auth-test and --launch\n", .{});
        },
        ArgError.MissingSession => {
            std.debug.print("ERROR: --session <name> is required for --launch\n", .{});
        },
    }
}

// =============================================================================
// Terminal echo control for password input
// =============================================================================
//
// When reading a password we turn off echo on the controlling tty so
// keystrokes don't appear on screen. The state is restored on completion
// (success, failure, or error path).

const TermState = struct {
    fd: c_int,
    saved: c.struct_termios,
};

fn disableEcho(fd: c_int) ?TermState {
    var saved: c.struct_termios = undefined;
    if (c.tcgetattr(fd, &saved) != 0) return null;

    var modified = saved;
    // Clear the ECHO bit in the local-mode flags.
    modified.c_lflag &= ~@as(c.tcflag_t, c.ECHO);

    if (c.tcsetattr(fd, c.TCSANOW, &modified) != 0) return null;
    return TermState{ .fd = fd, .saved = saved };
}

fn restoreEcho(state: TermState) void {
    _ = c.tcsetattr(state.fd, c.TCSANOW, &state.saved);
}

// =============================================================================
// CLI conversation. Talks to stdin/stderr.
// =============================================================================
//
// stderr is used for prompts and messages so that any future structured
// output on stdout (e.g. JSON for scripted callers) stays clean.

const CliConv = struct {
    allocator: std.mem.Allocator,

    fn respond(
        ctx: *anyopaque,
        style: c_int,
        prompt: []const u8,
    ) anyerror!?[*:0]u8 {
        const self: *CliConv = @ptrCast(@alignCast(ctx));

        const stderr = compat.fs.stderr();
        _ = stderr.writeAll(prompt) catch {};
        // PAM prompts conventionally don't include trailing space; add one.
        if (prompt.len > 0 and prompt[prompt.len - 1] != ' ') {
            _ = stderr.writeAll(" ") catch {};
        }

        switch (style) {
            pam.PROMPT_ECHO_OFF, pam.PROMPT_ECHO_ON => {
                // Read a line of input. For ECHO_OFF, suppress echo on
                // stdin during the read.
                const stdin_fd: c_int = posix.STDIN_FILENO;
                const term: ?TermState = if (style == pam.PROMPT_ECHO_OFF)
                    disableEcho(stdin_fd)
                else
                    null;

                const line_opt = readLine(self.allocator) catch |err| {
                    if (term) |t| {
                        restoreEcho(t);
                        _ = stderr.writeAll("\n") catch {};
                    }
                    return err;
                };

                if (term) |t| {
                    restoreEcho(t);
                    // Echo a newline since the user's Enter wasn't shown.
                    _ = stderr.writeAll("\n") catch {};
                }

                const line = line_opt orelse return error.UnexpectedEof;

                // Convert to a malloc-allocated null-terminated string that
                // libpam can free(3). We can't return Zig-allocator memory
                // to a C library that uses free().
                const raw = std.c.malloc(line.len + 1) orelse {
                    self.allocator.free(line);
                    return error.OutOfMemory;
                };
                const dst: [*]u8 = @ptrCast(raw);
                @memcpy(dst[0..line.len], line);
                dst[line.len] = 0;
                self.allocator.free(line);
                return @ptrCast(raw);
            },
            pam.ERROR_MSG, pam.TEXT_INFO => {
                _ = stderr.writeAll("\n") catch {};
                return null;
            },
            else => {
                // Unknown style: treat as informational.
                _ = stderr.writeAll("\n") catch {};
                return null;
            },
        }
    }

    fn readLine(allocator: std.mem.Allocator) !?[]u8 {
        var buf = std.ArrayList(u8).empty;
        defer buf.deinit(allocator);

        var chunk: [1]u8 = undefined;
        while (true) {
            const n = posix.read(posix.STDIN_FILENO, &chunk) catch |err| return err;
            if (n == 0) {
                if (buf.items.len == 0) return null;
                break;
            }
            if (chunk[0] == '\n') break;
            try buf.append(allocator, chunk[0]);
        }

        return try buf.toOwnedSlice(allocator);
    }
};

// =============================================================================
// BufferedConv: PAM conversation for Stage 6 graphical login
// =============================================================================
//
// Pre-collected credentials. The UI gathers the password into
// state.password before transitioning to .submitting; this
// conversation borrows that buffer and serves it to libpam on the
// first PROMPT_ECHO_OFF call.
//
// Multiple PROMPT_ECHO_OFF calls are possible if the PAM stack has
// multiple auth modules that each prompt; we serve the same buffer
// each time. (This matches the standard "single password covers all
// auth modules" UX.)
//
// PROMPT_ECHO_ON should not happen for a Stage 6 transaction since
// pam.start is called with the username already supplied; we
// implement it defensively by returning the username buffer too.
//
// ERROR_MSG / TEXT_INFO are routed to a callback (typically a
// closure capturing &state.status_message) so the UI can surface
// PAM-side messages.

const BufferedConv = struct {
    allocator: std.mem.Allocator,
    username: []const u8,
    password: []const u8,
    // Optional sink for ERROR_MSG / TEXT_INFO. The slice is borrowed
    // from the libpam-supplied prompt and is only valid for the
    // duration of this call. The sink is responsible for copying if
    // it wants to keep the message past this respond() call.
    on_message: ?*const fn (ctx: *anyopaque, style: c_int, message: []const u8) void = null,
    on_message_ctx: ?*anyopaque = null,

    fn respond(
        ctx: *anyopaque,
        style: c_int,
        prompt: []const u8,
    ) anyerror!?[*:0]u8 {
        const self: *BufferedConv = @ptrCast(@alignCast(ctx));

        switch (style) {
            pam.PROMPT_ECHO_OFF => return dupCStr(self.allocator, self.password),
            pam.PROMPT_ECHO_ON => return dupCStr(self.allocator, self.username),
            pam.ERROR_MSG, pam.TEXT_INFO => {
                if (self.on_message) |cb| cb(self.on_message_ctx.?, style, prompt);
                return null;
            },
            else => {
                if (self.on_message) |cb| cb(self.on_message_ctx.?, style, prompt);
                return null;
            },
        }
    }

    fn dupCStr(allocator: std.mem.Allocator, src: []const u8) anyerror!?[*:0]u8 {
        // libpam frees the returned buffer with free(3); allocate
        // with std.c.malloc so the free is matched. Zig allocators
        // are off-limits because their free is incompatible with
        // C's free.
        _ = allocator;
        const raw = std.c.malloc(src.len + 1) orelse return error.OutOfMemory;
        const dst: [*]u8 = @ptrCast(raw);
        @memcpy(dst[0..src.len], src);
        dst[src.len] = 0;
        return @ptrCast(raw);
    }
};

// =============================================================================
// PAM service selection
// =============================================================================
//
// Stage 1 prefers /etc/pam.d/pgsd-sessiond. If that file doesn't exist
// yet (it won't until install.sh ships the file from ADR 0002), fall
// back to "login". Later stages will require the pgsd-sessiond service
// to be installed and refuse to fall back; stage 1 is transitional.

const SERVICE_PRIMARY: [:0]const u8 = "pgsd-sessiond";
const SERVICE_FALLBACK: [:0]const u8 = "login";

fn selectService() [:0]const u8 {
    if (posix.system.access("/etc/pam.d/pgsd-sessiond", posix.F_OK) != 0) {
        std.debug.print(
            "note: /etc/pam.d/pgsd-sessiond not installed; falling back to PAM service \"login\"\n",
            .{},
        );
        return SERVICE_FALLBACK;
    }
    return SERVICE_PRIMARY;
}

// =============================================================================
// Main
// =============================================================================

pub fn main(init: std.process.Init.Minimal) u8 {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const argv_owned = compat.args.alloc(alloc, init.args) catch {
        std.debug.print("ERROR: failed to allocate argv\n", .{});
        return EXIT_INTERNAL;
    };
    defer argv_owned.deinit(alloc);
    const argv = argv_owned.argv;

    const args = parseArgs(argv) catch |err| {
        printArgError(err, argv);
        printUsage(compat.fs.stderr());
        return EXIT_USAGE;
    };

    if (args.auth_test) return runAuthTest(alloc, args);
    if (args.list_users) return runListUsers(alloc);
    if (args.list_sessions) return runListSessions(alloc);
    if (args.launch) return runLaunch(alloc, args);
    if (args.ui_only) return runUiOnly(alloc);

    // Unreachable: parseArgs enforces that exactly one mode is set.
    unreachable;
}

fn runAuthTest(alloc: std.mem.Allocator, args: Args) u8 {
    const user_z = alloc.dupeZ(u8, args.user.?) catch {
        std.debug.print("ERROR: out of memory\n", .{});
        return EXIT_INTERNAL;
    };
    defer alloc.free(user_z);

    const service = selectService();

    var conv_ctx = CliConv{ .allocator = alloc };
    const conv = pam.Conversation{
        .ctx = &conv_ctx,
        .respond_fn = CliConv.respond,
    };

    var transaction = pam.Pam{};
    transaction.start(service, user_z, &conv) catch |err| {
        std.debug.print("ERROR: pam_start failed: {s}\n", .{@errorName(err)});
        return EXIT_INTERNAL;
    };
    defer transaction.end(pam.PAM_SUCCESS);

    transaction.authenticate() catch |err| {
        return reportAndExit(&transaction, err, "authentication");
    };

    transaction.acctMgmt() catch |err| {
        return reportAndExit(&transaction, err, "account management");
    };

    const final_user = transaction.getUser() catch |err| {
        std.debug.print(
            "WARN: authenticated but could not retrieve PAM_USER: {s}\n",
            .{@errorName(err)},
        );
        return EXIT_OK;
    };

    std.debug.print("ok: authenticated as {s} (service: {s})\n", .{ final_user, service });
    return EXIT_OK;
}

fn runListUsers(alloc: std.mem.Allocator) u8 {
    var list = user_enum.enumerate(alloc) catch |err| {
        std.debug.print("ERROR: user enumeration failed: {s}\n", .{@errorName(err)});
        return EXIT_INTERNAL;
    };
    defer list.deinit(alloc);

    const stdout = compat.fs.stdout();
    var buf: [4096]u8 = undefined;

    for (list.users.items) |*u| {
        // Tab-separated, roughly grep-friendly. Display name in quotes
        // so embedded spaces parse cleanly with awk -F$'\t'.
        const line = std.fmt.bufPrint(
            &buf,
            "{s}\tuid={d}\tshell={s}\t\"{s}\"",
            .{ u.name, u.uid, u.shell, u.displayName() },
        ) catch continue;
        _ = stdout.writeAll(line) catch {};

        if (u.attrs.default_session) |s| {
            const extra = std.fmt.bufPrint(&buf, "\tsession={s}", .{s}) catch continue;
            _ = stdout.writeAll(extra) catch {};
        }
        if (u.attrs.capabilities.items.len > 0) {
            _ = stdout.writeAll("\tcaps=") catch {};
            for (u.attrs.capabilities.items, 0..) |cap, idx| {
                if (idx > 0) _ = stdout.writeAll(",") catch {};
                _ = stdout.writeAll(cap) catch {};
            }
        }
        _ = stdout.writeAll("\n") catch {};

        // Per-user attribute warnings go to stderr; doesn't pollute
        // the parseable stdout output.
        for (u.attrs.warnings.items) |w| {
            std.debug.print("warn ({s}): {s}\n", .{ u.name, w });
        }
    }

    return EXIT_OK;
}

fn runListSessions(alloc: std.mem.Allocator) u8 {
    var result = session_file.enumerate(alloc) catch |err| {
        std.debug.print("ERROR: session enumeration failed: {s}\n", .{@errorName(err)});
        return EXIT_INTERNAL;
    };
    defer result.deinit(alloc);

    const stdout = compat.fs.stdout();
    var buf: [8192]u8 = undefined;

    for (result.sessions.items) |*s| {
        // Tab-separated, matching --list-users style for parseability.
        // <id>\tname="<name>"\texec=<exec>[\tcomment="<comment>"]
        const line = std.fmt.bufPrint(
            &buf,
            "{s}\tname=\"{s}\"\texec={s}",
            .{ s.id, s.name, s.exec },
        ) catch continue;
        _ = stdout.writeAll(line) catch {};

        if (s.comment) |cm| {
            const extra = std.fmt.bufPrint(&buf, "\tcomment=\"{s}\"", .{cm}) catch continue;
            _ = stdout.writeAll(extra) catch {};
        }
        _ = stdout.writeAll("\n") catch {};
    }

    // Per-file warnings go to stderr; doesn't pollute the parseable
    // stdout output. ADR 0004 §Discovery line 194: malformed files
    // log a warning and skip; this is where the warnings surface.
    for (result.warnings.items) |w| {
        std.debug.print("warn ({s}): {s}\n", .{ w.filename, w.reason });
    }

    return EXIT_OK;
}

fn runUiOnly(alloc: std.mem.Allocator) u8 {
    // Full graphical login flow with session looping.
    //
    // The OUTER loop runs one complete login session per iteration:
    // connection setup, surface creation, login UI render+poll,
    // PAM auth, .session resolution, fork+exec, wait for session
    // leader to exit. When the session leader exits, the outer
    // loop continues: a fresh login screen appears, awaiting the
    // next user.
    //
    // Per ADR 0001 §Logout, lines 320-325: "The session ends when
    // the session leader process exits. pgsd-sessiond observes
    // the exit via the wait(2) family, calls pam_close_session,
    // tears down the session-specific PAM handle, and re-displays
    // the login UI." This is the daemon's bounded responsibility:
    // "authenticate, launch, clean up on session exit, return to
    // the login screen."
    //
    // The outer loop exits only on:
    //   - SIGTERM (or similar): pgsd-sessiond is killed by init
    //     after Stage 8's shutdown/restart commit the system. The
    //     loop never returns normally for those paths; we're gone.
    //   - An unrecoverable setup error (connect, surface create) ->
    //     EXIT_INTERNAL
    //   - A semadraw disconnect mid-session (AppEvent.quit from
    //     drainUiEvents) -> EXIT_INTERNAL
    //   - A terminal PAM error (account expired, perm denied,
    //     service misconfiguration) -> the corresponding stage-3/4
    //     exit code. These propagate out because they indicate a
    //     system problem, not a user-input problem.
    //
    // Stage 8 removed the Ctrl-Q-quits-the-daemon path that earlier
    // stages had. Ctrl-Q now opens the power menu; the operator
    // shuts down, restarts, or suspends via that menu instead. The
    // only way to stop the daemon without going through init is to
    // send it SIGTERM from another shell (used by the supervisor
    // in Stage 9).
    //
    // Three auth failures in a row are NOT a daemon exit condition
    // (would be a DoS attack vector). The user simply sees the
    // login screen again with a "too many attempts" message. The
    // attempts counter resets when the screen is redisplayed.
    //
    // Per-iteration:
    //   1. Open connection to semadrawd. (Re-opening is robust
    //      against daemon restarts between sessions.)
    //   2. Query framebuffer dimensions; create native-sized surface.
    //   3. Initialise UI state; gather sysinfo (hostname/network/memory).
    //   4. Render+poll loop. When the user submits a password, the UI
    //      transitions state.field to .submitting. When the user opens
    //      the power menu and confirms an action, ui sets
    //      state.power_action; main reads it and invokes the
    //      corresponding FreeBSD command via c.system().
    //   5. On .submitting, perform PAM auth using a BufferedConv that
    //      serves state.username and state.password from memory.
    //   6. On retryable AUTH FAIL: state.resetForRetry, continue
    //      inner loop with attempt counter decremented; on
    //      retries-exhausted, the outer loop redisplays a fresh
    //      login screen with the message.
    //   7. On terminal PAM error: return the appropriate exit code
    //      (terminal errors propagate out of the daemon).
    //   8. On AUTH SUCCESS: resolve session via Stage 7's
    //      selected_session.sessionId(), tear down surface and
    //      connection, call launch_mod.launch() which fork+execs
    //      the session leader and waits for its exit. When the
    //      session leader exits, the outer loop continues:
    //      reconnect, recreate surface, redisplay login UI.
    //   9. On power action: invoke shutdown/restart/suspend command.
    //      Shutdown/restart commit to init's hands; we keep
    //      rendering "Shutting down..." until init kills us.
    //      Suspend blocks until resume; on return we restore the
    //      pre-menu field and continue.
    //
    // Must run as root: PAM session-open needs root, setusercontext
    // needs root, and the /var/run/pgsd/<uid>/ chown needs root.

    if (c.geteuid() != 0) {
        std.debug.print(
            "ERROR: --ui-only requires root privileges (run via doas or as root)\n",
            .{},
        );
        return EXIT_USAGE;
    }

    // Stage 9: install signal handlers for graceful shutdown under
    // s6 supervision. SIGTERM is sent by `s6-svc -d`; we set a flag
    // and the loops below poll it. This must be done before opening
    // any semadrawd resources so that a stop request that arrives
    // during setup also exits cleanly.
    installSignalHandlers();

    // Encoder is reused across all login iterations. It has no
    // daemon-side resource and no per-session state; just SDCS
    // byte accumulation. Resetting at the top of each frame
    // clears it.
    var encoder = semadraw.Encoder.init(alloc);
    defer encoder.deinit();

    // Status message carried over from a prior login session
    // (e.g. "session exited quickly; check configuration", or
    // "too many failed attempts"). Backed by post_launch_status_buf
    // since the buffer that originated the message goes out of
    // scope when its inner loop ends.
    var post_login_status: ?[]const u8 = null;
    var post_login_status_buf: [128]u8 = undefined;

    // Outer session loop. Each iteration is one login session.
    outer: while (true) {
        // Stage 9: check for shutdown request before opening any
        // resources for this iteration. If we got SIGTERM while
        // launch() was running a session, we'd see the flag here
        // immediately after launch returns.
        if (shutdown_requested.load(.seq_cst)) {
            return EXIT_OK;
        }

        var state = ui.State.init(alloc) catch |err| {
            std.debug.print("ERROR: ui state init failed: {s}\n", .{@errorName(err)});
            return EXIT_INTERNAL;
        };
        // If the prior session left a status message for us
        // (post-launch advisory, or retry exhaustion), surface it
        // on the fresh login screen until the user starts typing.
        if (post_login_status) |msg| {
            state.status_message = msg;
            post_login_status = null;
        }

        // Open the connection. We reconnect each iteration rather
        // than reusing across sessions; this is robust against
        // semadrawd restarting while the user's session was running.
        var conn = semadraw.client.connect(alloc) catch |err| {
            std.debug.print("ERROR: connecting to semadrawd: {s}\n", .{@errorName(err)});
            std.debug.print("       Is semadrawd running and accessible at /var/run/semadraw.sock?\n", .{});
            state.deinit();
            return EXIT_INTERNAL;
        };

        // Query the framebuffer dimensions. On failure, fall back
        // to the sparrow-sized default so the login screen still
        // renders; semadrawd will window-clip if the surface is
        // bigger than the display, which is the right failure mode
        // for a login screen.
        var fb_w: u32 = ui.FALLBACK_WIDTH;
        var fb_h: u32 = ui.FALLBACK_HEIGHT;
        if (conn.queryOutputInfo(0)) |info| {
            fb_w = info.width;
            fb_h = info.height;
            std.debug.print(
                "fullscreen: framebuffer {}x{} at scale {}\n",
                .{ fb_w, fb_h, ui.SCALE },
            );
        } else |err| {
            std.debug.print(
                "WARN: queryOutputInfo failed ({s}); falling back to {}x{}\n",
                .{ @errorName(err), fb_w, fb_h },
            );
        }

        const surface_w_f: f32 = @floatFromInt(fb_w);
        const surface_h_f: f32 = @floatFromInt(fb_h);

        // Create the surface at framebuffer dimensions. No
        // daemon-side scale is requested; we render at SCALE x
        // ourselves via the cell_width and cell_height passed to
        // drawGlyphRun, matching semadraw-term's pattern.
        var surface = semadraw.client.Surface.create(conn, surface_w_f, surface_h_f) catch |err| {
            std.debug.print("ERROR: surface.create failed: {s}\n", .{@errorName(err)});
            conn.disconnect();
            state.deinit();
            return EXIT_INTERNAL;
        };
        surface.show() catch |err| {
            std.debug.print("ERROR: surface.show failed: {s}\n", .{@errorName(err)});
            surface.destroy();
            conn.disconnect();
            state.deinit();
            return EXIT_INTERNAL;
        };

        // Note: surface.destroy() and conn.disconnect() are NOT in
        // a single deferred block, because the auth-success path
        // needs to tear them down EXPLICITLY before calling
        // launch() (so the child process doesn't inherit them).
        // If we reach a normal continue or return path without
        // auth success, the manual cleanup at the bottom of this
        // iteration handles teardown.

        // Frame pacing identical to App's pattern.
        const frame_ns: u64 = @divTrunc(std.time.ns_per_s, ui.TARGET_FPS);
        var running = true;
        // SM-4: redraws are gated on actual change. The 30 Hz loop
        // cadence remains (cheap timestamp checks per pass), but the
        // render-encode-commit chain runs only when this flag is set:
        // first frame, key-driven state changes (drainUiEvents),
        // network string replacement, auth submission, and wall-clock
        // caret-blink phase flips once typing has started. Before the
        // first keystroke the caret is solid, so a hands-off login
        // screen commits nothing at all.
        var needs_redraw = true;
        var last_blink_phase: u64 = 0;


        // Per-conversation status buffer. Auth attempts format
        // their failure messages here and hand a slice to
        // state.resetForRetry. Single buffer since the user only
        // ever sees one message at a time.
        var status_buf: [256]u8 = undefined;

        // Retry counter. 3 attempts per login screen; on
        // exhaustion the outer loop redisplays the login screen
        // with a "too many attempts" message and resets to 3.
        var attempts_remaining: u32 = 3;

        // Inner loop: one user's path through identify -> password
        // -> (optional picker) -> submission -> auth outcome.
        while (running) {
            const frame_start = compat.time.nowMonotonic();

            // Refresh network state on the cadence configured by
            // ui.NETWORK_REFRESH_INTERVAL_MS. Cheap when throttled
            // (just a timestamp comparison); does a getifaddrs walk
            // when the interval elapses. Necessary because
            // sysinfo.network() at State.init can run before DHCP
            // completes, snapshotting "no network" for a machine
            // that comes online a few seconds later.
            if (state.maybeRefreshNetwork()) needs_redraw = true;

            // SM-4: wall-clock caret blink phase; a flip warrants a
            // redraw only once typing has started (solid before).
            const now_ms = @as(i64, @intCast(@divTrunc(compat.time.nowMonotonic(), std.time.ns_per_ms)));
            const blink_phase: u64 = @intCast(@mod(@divTrunc(now_ms, ui.CURSOR_BLINK_MS), 2));
            if (blink_phase != last_blink_phase) {
                last_blink_phase = blink_phase;
                if (state.typing_started) needs_redraw = true;
            }

            // Render this frame, only if something changed (SM-4).
            if (needs_redraw) {
            needs_redraw = false;
            encoder.reset() catch |err| {
                std.debug.print("ERROR: encoder.reset failed: {s}\n", .{@errorName(err)});
                surface.destroy();
                conn.disconnect();
                state.deinit();
                return EXIT_INTERNAL;
            };
            // Layout selection. PGSD_SESSIOND_LAYOUT=console selects the
            // two-pane operating-system console prototype; anything else
            // (including unset) keeps the centered login card. The
            // prototype renders the same State and does not change any
            // behavior, so this is a pure presentation switch and is
            // safe to flip on a running bench.
            ui.draw(&state, &encoder, blink_phase, surface_w_f, surface_h_f) catch |err| {
                std.debug.print("ERROR: ui.draw failed: {s}\n", .{@errorName(err)});
                surface.destroy();
                conn.disconnect();
                state.deinit();
                return EXIT_INTERNAL;
            };
            const sdcs = encoder.finishBytesWithHeader() catch |err| {
                std.debug.print("ERROR: encoder.finishBytesWithHeader failed: {s}\n", .{@errorName(err)});
                surface.destroy();
                conn.disconnect();
                state.deinit();
                return EXIT_INTERNAL;
            };
            defer alloc.free(sdcs);

            surface.attachAndCommit(sdcs) catch |err| {
                std.debug.print("ERROR: surface.attachAndCommit failed: {s}\n", .{@errorName(err)});
                surface.destroy();
                conn.disconnect();
                state.deinit();
                return EXIT_INTERNAL;
            };
            }

            // Drain pending events.
            var ui_dirty = false;
            running = drainUiEvents(&state, conn, &ui_dirty) catch |err| {
                std.debug.print("ERROR: event drain failed: {s}\n", .{@errorName(err)});
                surface.destroy();
                conn.disconnect();
                state.deinit();
                return EXIT_INTERNAL;
            };
            if (!running) {
                // drainUiEvents returned false: semadrawd
                // disconnected (AppEvent.quit). We can't render
                // anymore; the daemon vanished. Treat as fatal.
                std.debug.print("ERROR: semadraw connection lost\n", .{});
                surface.destroy();
                conn.disconnect();
                state.deinit();
                return EXIT_INTERNAL;
            }

            // Stage 9: check for SIGTERM/SIGINT/SIGHUP. If the
            // supervisor (or operator) asked us to stop, tear down
            // cleanly and exit with EXIT_OK so s6's flap protection
            // sees a normal exit, not a fast crash.
            if (shutdown_requested.load(.seq_cst)) {
                surface.destroy();
                conn.disconnect();
                state.deinit();
                return EXIT_OK;
            }

            if (ui_dirty) needs_redraw = true;

            // Handle submission. Entering this block always changes
            // visible state (retry message, attempt counter, or the
            // launch path leaves the UI entirely), so it warrants a
            // redraw regardless of outcome (SM-4).
            if (state.field == .submitting) {
                needs_redraw = true;
                const outcome = attemptAuth(alloc, &state, &status_buf, attempts_remaining);
                switch (outcome) {
                    .success => |s_const| {
                        // Auth succeeded; we have everything needed
                        // to launch the session. Tear down the UI
                        // BEFORE calling launch() so the child
                        // doesn't inherit our surface or connection.
                        var s = s_const;
                        surface.destroy();
                        conn.disconnect();
                        const launch_start_ns = compat.time.nowMonotonic();
                        const child_exit = doLaunch(alloc, &s);
                        const launch_elapsed_ns: u64 = @intCast(
                            compat.time.nowMonotonic() - launch_start_ns,
                        );
                        s.user.deinit(alloc);
                        s.session.deinit(alloc);
                        s.transaction.end(pam.PAM_SUCCESS);

                        // Session ended. If the leader exited
                        // suspiciously fast (<2s) AND with a non-zero
                        // code, leave a message on the next login screen
                        // so the user isn't left wondering why nothing
                        // happened. 2s heuristic: a normal interactive
                        // session takes much longer; a fast non-zero
                        // exit usually means an exec failure or a
                        // misconfigured .session file.
                        //
                        // SM-5: the exit-code gate is essential. launch()
                        // maps fork/exec/setusercontext/setsid failures
                        // to non-zero codes (EXIT_LAUNCH_FAILED,
                        // EXIT_INTERNAL); a clean logout returns the
                        // leader's exit status (0). A fast code-0 exit is
                        // a deliberate short session (log in, log straight
                        // back out), not a config problem, so it stays
                        // silent.
                        const QUICK_EXIT_THRESHOLD_NS: u64 = 2 * std.time.ns_per_s;
                        if (child_exit != 0 and launch_elapsed_ns < QUICK_EXIT_THRESHOLD_NS) {
                            post_login_status = std.fmt.bufPrint(
                                &post_login_status_buf,
                                "session exited quickly (code {d}); check configuration",
                                .{child_exit},
                            ) catch null;
                        }

                        state.deinit();
                        // Skip the per-iteration teardown below;
                        // surface and conn are already gone.
                        continue :outer;
                    },
                    .retry => |msg| {
                        attempts_remaining -= 1;
                        if (attempts_remaining == 0) {
                            // Exhausted. Stash the message for the
                            // fresh login screen on the next outer
                            // iteration, then break out of the
                            // inner loop. (Not a daemon exit; the
                            // operator can shut down from the next
                            // login screen via Ctrl-Q -> power menu.)
                            post_login_status = std.fmt.bufPrint(
                                &post_login_status_buf,
                                "too many failed attempts; try again",
                                .{},
                            ) catch "too many failed attempts";
                            break;
                        }
                        state.resetForRetry(msg);
                    },
                    .fatal => |f| {
                        // Terminal PAM error: indicates a system
                        // problem (account expired, perm denied,
                        // service misconfiguration). Exit the
                        // daemon with the appropriate stage-3/4
                        // code. The operator (or supervisor) can
                        // address and restart.
                        std.debug.print("ERROR: {s}\n", .{f.message});
                        surface.destroy();
                        conn.disconnect();
                        state.deinit();
                        return f.exit_code;
                    },
                }
            }

            // Stage 8: handle a confirmed power action. state.power_action
            // is set by the ui when the user confirms Y on a destructive
            // option, or selects Suspend (which has no confirm). Three
            // dispositions:
            //
            //   - .shutdown / .restart: invoke the FreeBSD command via
            //     c.system(). The command requests init to do work and
            //     returns quickly. After it returns, we leave
            //     power_action set so draw() renders "Shutting down..."
            //     and continue rendering. Init will send us SIGTERM
            //     within the shutdown grace period (typically a few
            //     seconds).
            //
            //   - .suspend_: c.system("acpiconf -s 3") blocks until the
            //     system resumes. After it returns, clear power_action,
            //     return to pre_power_field, and continue. The login
            //     screen the user wakes to is the same login screen
            //     they suspended from.
            //
            // Safety net: if shutdown/restart's system() call returns
            // a non-zero status (couldn't find the binary, lacked
            // privilege, etc.), don't trap the user in a "Shutting
            // down..." screen they can't escape. Clear power_action
            // and surface a status_message explaining what went wrong.
            // The user can try again or pick a different option.
            // ADR 0011: Power is a peer view, so the armed action is
            // gated on the VIEW, not on a modal field.
            if (state.power_action) |action| if (state.view == .power and
                state.power_menu_phase != .in_progress)
            {
                switch (action) {
                    .shutdown => {
                        state.power_menu_phase = .in_progress;
                        const rc = c.system("shutdown -p now");
                        if (rc != 0) {
                            // Command failed. Clear the armed action,
                            // back out of the in-progress display, and
                            // surface the failure to the user.
                            state.power_action = null;
                            state.power_menu_phase = .choosing;
                            state.status_message = std.fmt.bufPrint(
                                &post_login_status_buf,
                                "shutdown failed (rc={d}); is /sbin/shutdown installed?",
                                .{rc},
                            ) catch "shutdown failed";
                        }
                        // On success: stay in .power_menu with phase
                        // .in_progress; the next render shows
                        // "Shutting down..." while we wait for init
                        // to kill us. No need to do anything else
                        // here.
                    },
                    .restart => {
                        state.power_menu_phase = .in_progress;
                        const rc = c.system("shutdown -r now");
                        if (rc != 0) {
                            state.power_action = null;
                            state.power_menu_phase = .choosing;
                            state.status_message = std.fmt.bufPrint(
                                &post_login_status_buf,
                                "restart failed (rc={d}); is /sbin/shutdown installed?",
                                .{rc},
                            ) catch "restart failed";
                        }
                    },
                    .suspend_ => {
                        // Render one frame to show the user something
                        // happened, then block in acpiconf. The frame
                        // already went out at the top of this loop
                        // iteration; the user sees "Suspending..."
                        // until wake.
                        state.power_menu_phase = .in_progress;
                        const rc = c.system("acpiconf -s 3");
                        // acpiconf returns when the system has resumed.
                        // Restore the menu's resting state, return to
                        // pre_power_field, and continue.
                        state.power_action = null;
                        state.power_menu_phase = .choosing;
                        // ADR 0011: Power covered nothing to get here,
                        // so there is nothing to restore. Return to the
                        // rail.
                        state.focus = .rail;
                        state.rail_cursor = .power;
                        if (rc != 0) {
                            state.status_message = std.fmt.bufPrint(
                                &post_login_status_buf,
                                "suspend failed (rc={d}); is acpiconf supported?",
                                .{rc},
                            ) catch "suspend failed";
                        }
                    },
                }
            };

            // Frame pacing.
            const elapsed: u64 = @intCast(compat.time.nowMonotonic() - frame_start);
            if (elapsed < frame_ns) {
                compat.time.sleep(compat.time.Duration.fromNanoseconds(frame_ns - elapsed));
            }
        }

        // Inner loop ended via the retries-exhausted break above.
        // (Disconnect was handled inline.) post_login_status is
        // already set; tear down and loop.
        surface.destroy();
        conn.disconnect();
        state.deinit();
        // Fall through to the outer loop's continue.
        // Fall through to the outer loop's continue.
    }
}

// =============================================================================
// Auth attempt + launch helpers
// =============================================================================

const ReadyToLaunch = struct {
    user: user_enum.EnumeratedUser,
    session: session_file.SessionFile,
    transaction: pam.Pam,
};

const FatalOutcome = struct {
    message: []const u8,
    exit_code: u8,
};

const AuthOutcome = union(enum) {
    success: ReadyToLaunch,
    retry: []const u8, // borrowed message
    fatal: FatalOutcome, // message + exit code
};

/// Attempt one auth + acctMgmt + session-resolve cycle. On success,
/// returns the ready-to-launch handles. On retryable failure, returns
/// .retry with a formatted message. On terminal failure, returns
/// .fatal with the message and exit code.
///
/// status_buf is borrowed for message formatting; the returned slice
/// in .retry / .fatal points into it and is valid until the next
/// attemptAuth call.
///
/// All early-return paths that allocated resources (user, transaction)
/// clean those resources up before returning. The .success path
/// transfers ownership to the caller, which is responsible for
/// user.deinit, session.deinit, and transaction.end.
fn attemptAuth(
    alloc: std.mem.Allocator,
    state: *ui.State,
    status_buf: *[256]u8,
    attempts_remaining: u32,
) AuthOutcome {
    // 1. Resolve user. No resources held yet on early return.
    const user_opt = user_enum.lookupByName(alloc, state.username.items) catch {
        return .{ .fatal = .{
            .message = "internal error: user lookup failed",
            .exit_code = EXIT_INTERNAL,
        } };
    };
    if (user_opt == null) {
        // No such user. Per UX convention, treat this the same as
        // wrong password to avoid leaking which usernames exist.
        const msg = std.fmt.bufPrint(
            status_buf,
            "authentication failed; {d} attempts remaining",
            .{attempts_remaining - 1},
        ) catch "authentication failed";
        return .{ .retry = msg };
    }
    var user = user_opt.?;

    // From here on, every non-success return must call user.deinit.
    // We track this with `user_owned` and free at each early return.
    var user_owned: bool = true;
    defer if (user_owned) user.deinit(alloc);

    // 2. Set up PAM with a BufferedConv that reads username and
    //    password from state.
    const user_z = alloc.dupeZ(u8, user.name) catch {
        return .{ .fatal = .{
            .message = "internal error: out of memory",
            .exit_code = EXIT_INTERNAL,
        } };
    };
    defer alloc.free(user_z);

    const service = selectService();

    var conv_ctx = BufferedConv{
        .allocator = alloc,
        .username = user.name,
        .password = state.password.items,
    };
    const conv = pam.Conversation{
        .ctx = &conv_ctx,
        .respond_fn = BufferedConv.respond,
    };

    var transaction = pam.Pam{};
    transaction.start(service, user_z, &conv) catch {
        return .{ .fatal = .{
            .message = "internal error: pam_start failed",
            .exit_code = EXIT_INTERNAL,
        } };
    };

    // From here on, every non-success return must end the transaction.
    var transaction_owned: bool = true;
    defer if (transaction_owned) transaction.end(pam.PAM_SUCCESS);

    // 3. Authenticate.
    transaction.authenticate() catch |err| switch (err) {
        pam.Error.AuthFailed, pam.Error.UserUnknown => {
            // UserUnknown gets the same masking as a wrong password
            // to avoid leaking which usernames exist.
            const msg = std.fmt.bufPrint(
                status_buf,
                "authentication failed; {d} attempts remaining",
                .{attempts_remaining - 1},
            ) catch "authentication failed";
            return .{ .retry = msg };
        },
        pam.Error.MaxTries => {
            return .{ .fatal = .{
                .message = "too many attempts; locked out by PAM",
                .exit_code = EXIT_MAX_TRIES,
            } };
        },
        pam.Error.ServiceError => {
            return .{ .fatal = .{
                .message = "PAM service configuration error",
                .exit_code = EXIT_PAM_SERVICE,
            } };
        },
        else => {
            const msg = std.fmt.bufPrint(
                status_buf,
                "authentication error: {s}",
                .{@errorName(err)},
            ) catch "authentication error";
            return .{ .fatal = .{ .message = msg, .exit_code = EXIT_AUTH_FAIL } };
        },
    };

    // 4. Account management.
    transaction.acctMgmt() catch |err| switch (err) {
        pam.Error.AccountExpired => {
            return .{ .fatal = .{
                .message = "account expired",
                .exit_code = EXIT_ACCOUNT_INVALID,
            } };
        },
        pam.Error.PermDenied => {
            return .{ .fatal = .{
                .message = "account access denied",
                .exit_code = EXIT_ACCOUNT_INVALID,
            } };
        },
        pam.Error.NewAuthTokRequired => {
            return .{ .fatal = .{
                .message = "password expired; change required (not supported in --ui-only)",
                .exit_code = EXIT_ACCOUNT_INVALID,
            } };
        },
        else => {
            const msg = std.fmt.bufPrint(
                status_buf,
                "account error: {s}",
                .{@errorName(err)},
            ) catch "account error";
            return .{ .fatal = .{ .message = msg, .exit_code = EXIT_ACCOUNT_INVALID } };
        },
    };

    // 5. Resolve session. Stage 7: the session id comes from the
    //    user-selected SessionType (default .terminal -> "default"),
    //    NOT from user.attrs.default_session. The picker's choice
    //    wins for this login; the per-user attribute is preserved
    //    in the attribute file for future use when more session
    //    backends exist.
    //
    //    user.attrs.default_session is intentionally ignored in v1.
    //    When additional session types come online with real
    //    backends, this code should change to seed selected_session
    //    from the user's attribute at picker-open time rather than
    //    overriding here.
    const session_id_str = state.selected_session.sessionId();
    const session_opt = session_file.lookupById(alloc, session_id_str) catch {
        return .{ .fatal = .{
            .message = "internal error: session lookup failed",
            .exit_code = EXIT_INTERNAL,
        } };
    };
    if (session_opt == null) {
        const msg = std.fmt.bufPrint(
            status_buf,
            "session not found: {s}/{s}.session",
            .{ session_file.DEFAULT_SESSIONS_DIR, session_id_str },
        ) catch "session not found";
        return .{ .fatal = .{ .message = msg, .exit_code = EXIT_SESSION_NOT_FOUND } };
    }

    // 6. Caller takes ownership of transaction / user / session.
    //    Clear the ownership flags so our defers don't fire.
    user_owned = false;
    transaction_owned = false;
    return .{ .success = .{
        .user = user,
        .session = session_opt.?,
        .transaction = transaction,
    } };
}

/// Auth has succeeded; call launch() and return its exit code.
/// The caller owns the resources in `ready` and must clean them up
/// after this function returns.
fn doLaunch(alloc: std.mem.Allocator, ready: *ReadyToLaunch) u8 {
    const exit_code = launch_mod.launch(
        alloc,
        &ready.transaction,
        &ready.user,
        ready.session.id,
        ready.session.exec,
    ) catch |err| return mapLaunchError(err);
    return exit_code;
}

// Pull every available event off the connection, translate to the
// AppEvent shape, dispatch through ui.handleEvent. Returns false
// when the state machine or a disconnection says to stop.
// SM-4: `dirty` is set when a state-mutating event was processed.
// Only key events qualify: frame_complete arrives for every commit
// we make, so counting it would turn the dirty flag into a
// self-sustaining redraw loop, and pointer events never reach
// handleEvent at all (the else => null arm below).
fn drainUiEvents(state: *ui.State, conn: *semadraw.client.Connection, dirty: *bool) !bool {
    const fd = conn.getFd();
    var pfd = [1]posix.pollfd{.{
        .fd = fd,
        .events = posix.POLL.IN,
        .revents = 0,
    }};

    while (true) {
        const ready = posix.poll(&pfd, 0) catch break;
        if (ready == 0) break;
        if ((pfd[0].revents & posix.POLL.IN) == 0) break;

        const ev = conn.waitEvent() catch |err| {
            if (err == error.EndOfStream or err == error.BrokenPipe) return false;
            break;
        };

        const app_ev: ?semadraw.AppEvent = switch (ev) {
            .disconnected => semadraw.AppEvent{ .quit = {} },
            .key_press => |kp| semadraw.AppEvent{ .key = .{
                .key_code = kp.key_code,
                .pressed = kp.pressed != 0,
                .modifiers = kp.modifiers,
            } },
            .frame_complete => |fc| semadraw.AppEvent{ .frame = .{
                .frame_number = fc.frame_number,
                .timestamp_ns = fc.timestamp_ns,
            } },
            else => null,
        };

        if (app_ev) |e| {
            if (e == .key) dirty.* = true;
            const keep = try ui.handleEvent(state, e);
            if (!keep) return false;
        }
    }

    return true;
}

fn runLaunch(alloc: std.mem.Allocator, args: Args) u8 {
    // Stages 3+4: resolve session, authenticate, drop privilege, exec.
    //
    // We require root because PAM session-open modules need root (utmp
    // updates, pam_lastlog), setusercontext needs root to apply login.conf
    // limits and to call setuid, and /var/run/pgsd/<uid>/ creation needs
    // root to chown the new directory. If we're not root, fail fast with
    // a clear message rather than failing partway through the launch.
    if (c.geteuid() != 0) {
        std.debug.print(
            "ERROR: --launch requires root privileges (run via sudo or as root)\n",
            .{},
        );
        return EXIT_USAGE;
    }

    // Resolve the session file BEFORE authenticating. If the session
    // doesn't exist or is malformed, we should report that immediately
    // rather than after wasting the user's password entry.
    const session_opt = session_file.lookupById(alloc, args.session.?) catch |err| switch (err) {
        session_file.LookupError.InvalidSessionId => {
            std.debug.print(
                "FAIL: invalid session id: {s}\n",
                .{args.session.?},
            );
            return EXIT_SESSION_INVALID;
        },
        session_file.LookupError.FileTooLarge => {
            std.debug.print(
                "FAIL: session file too large: {s}\n",
                .{args.session.?},
            );
            return EXIT_SESSION_INVALID;
        },
        session_file.LookupError.IoError => {
            std.debug.print(
                "FAIL: I/O error reading session file: {s}\n",
                .{args.session.?},
            );
            return EXIT_SESSION_INVALID;
        },
        session_file.LookupError.OutOfMemory => {
            std.debug.print("ERROR: out of memory\n", .{});
            return EXIT_INTERNAL;
        },
        else => {
            // Parse failure: malformed file.
            std.debug.print(
                "FAIL: session file malformed ({s}): {s}\n",
                .{ args.session.?, @errorName(err) },
            );
            return EXIT_SESSION_INVALID;
        },
    };
    if (session_opt == null) {
        std.debug.print(
            "FAIL: session not found: {s}\n",
            .{args.session.?},
        );
        return EXIT_SESSION_NOT_FOUND;
    }
    var session = session_opt.?;
    defer session.deinit(alloc);

    // Resolve the target user.
    const user_opt = user_enum.lookupByName(alloc, args.user.?) catch {
        std.debug.print("ERROR: user lookup failed (allocation)\n", .{});
        return EXIT_INTERNAL;
    };
    if (user_opt == null) {
        std.debug.print(
            "FAIL: user not found or not login-capable: {s}\n",
            .{args.user.?},
        );
        return EXIT_USER_UNKNOWN;
    }
    var user = user_opt.?;
    defer user.deinit(alloc);

    // Authenticate. Re-uses the stage 1 CliConv path; the user types
    // their password on the controlling tty just like --auth-test.
    const user_z = alloc.dupeZ(u8, user.name) catch {
        std.debug.print("ERROR: out of memory\n", .{});
        return EXIT_INTERNAL;
    };
    defer alloc.free(user_z);

    const service = selectService();

    var conv_ctx = CliConv{ .allocator = alloc };
    const conv = pam.Conversation{
        .ctx = &conv_ctx,
        .respond_fn = CliConv.respond,
    };

    var transaction = pam.Pam{};
    transaction.start(service, user_z, &conv) catch |err| {
        std.debug.print("ERROR: pam_start failed: {s}\n", .{@errorName(err)});
        return EXIT_INTERNAL;
    };
    defer transaction.end(pam.PAM_SUCCESS);

    transaction.authenticate() catch |err| {
        return reportAndExit(&transaction, err, "authentication");
    };

    transaction.acctMgmt() catch |err| {
        return reportAndExit(&transaction, err, "account management");
    };

    // Authenticated. Launch with pre-resolved session id and exec.
    const exit_code = launch_mod.launch(
        alloc,
        &transaction,
        &user,
        session.id,
        session.exec,
    ) catch |err| return mapLaunchError(err);

    return exit_code;
}

fn mapLaunchError(err: launch_mod.Error) u8 {
    std.debug.print("FAIL: launch: {s}\n", .{@errorName(err)});
    return switch (err) {
        launch_mod.Error.LoginCapAcquireFailed,
        launch_mod.Error.RuntimeDirCreateFailed,
        launch_mod.Error.ForkFailed,
        launch_mod.Error.SetusercontextFailed,
        launch_mod.Error.SetsidFailed,
        launch_mod.Error.ExecFailed,
        => EXIT_LAUNCH_FAILED,
        launch_mod.Error.OutOfMemory => EXIT_INTERNAL,
    };
}

fn reportAndExit(transaction: *pam.Pam, err: pam.Error, phase: []const u8) u8 {
    // transaction is plumbed in for future use (calling transaction.strerror
    // to print human-readable PAM error text). Stage 1 just reports the
    // Zig error name; the parameter stays so the signature is stable.
    _ = transaction;
    std.debug.print("FAIL: {s}: {s}\n", .{ phase, @errorName(err) });
    return switch (err) {
        pam.Error.AuthFailed => EXIT_AUTH_FAIL,
        pam.Error.UserUnknown => EXIT_USER_UNKNOWN,
        pam.Error.MaxTries => EXIT_MAX_TRIES,
        pam.Error.NewAuthTokRequired,
        pam.Error.AccountExpired,
        pam.Error.PermDenied,
        => EXIT_ACCOUNT_INVALID,
        pam.Error.ServiceError => EXIT_PAM_SERVICE,
        pam.Error.SystemError,
        pam.Error.Aborted,
        pam.Error.ConvError,
        pam.Error.Unknown,
        => EXIT_INTERNAL,
    };
}

// =============================================================================
// Tests
// =============================================================================
//
// Argument parsing tests run without PAM involvement. The PAM binding
// itself has its own test suite in pam.zig.

test "parseArgs accepts --auth-test --user <name>" {
    var a0 = "pgsd-sessiond".*;
    var a1 = "--auth-test".*;
    var a2 = "--user".*;
    var a3 = "vic".*;
    var argv: [4][:0]u8 = .{ a0[0..], a1[0..], a2[0..], a3[0..] };
    const args = try parseArgs(&argv);
    try std.testing.expect(args.auth_test);
    try std.testing.expectEqualStrings("vic", args.user.?);
}

test "parseArgs accepts --user=<name>" {
    var a0 = "pgsd-sessiond".*;
    var a1 = "--auth-test".*;
    var a2 = "--user=vic".*;
    var argv: [3][:0]u8 = .{ a0[0..], a1[0..], a2[0..] };
    const args = try parseArgs(&argv);
    try std.testing.expect(args.auth_test);
    try std.testing.expectEqualStrings("vic", args.user.?);
}

test "parseArgs rejects when no mode is selected" {
    var a0 = "pgsd-sessiond".*;
    var a1 = "--user".*;
    var a2 = "vic".*;
    var argv: [3][:0]u8 = .{ a0[0..], a1[0..], a2[0..] };
    try std.testing.expectError(ArgError.NoModeSelected, parseArgs(&argv));
}

test "parseArgs rejects --auth-test without --user" {
    var a0 = "pgsd-sessiond".*;
    var a1 = "--auth-test".*;
    var argv: [2][:0]u8 = .{ a0[0..], a1[0..] };
    try std.testing.expectError(ArgError.MissingUser, parseArgs(&argv));
}

test "parseArgs accepts --list-users without --user" {
    var a0 = "pgsd-sessiond".*;
    var a1 = "--list-users".*;
    var argv: [2][:0]u8 = .{ a0[0..], a1[0..] };
    const args = try parseArgs(&argv);
    try std.testing.expect(args.list_users);
    try std.testing.expect(args.user == null);
}

test "parseArgs rejects both --auth-test and --list-users" {
    var a0 = "pgsd-sessiond".*;
    var a1 = "--auth-test".*;
    var a2 = "--list-users".*;
    var a3 = "--user".*;
    var a4 = "vic".*;
    var argv: [5][:0]u8 = .{ a0[0..], a1[0..], a2[0..], a3[0..], a4[0..] };
    try std.testing.expectError(ArgError.MultipleModesSelected, parseArgs(&argv));
}

test "parseArgs rejects unknown flag" {
    var a0 = "pgsd-sessiond".*;
    var a1 = "--frobnicate".*;
    var argv: [2][:0]u8 = .{ a0[0..], a1[0..] };
    try std.testing.expectError(ArgError.UnknownFlag, parseArgs(&argv));
}

test "parseArgs rejects positional argument" {
    var a0 = "pgsd-sessiond".*;
    var a1 = "--auth-test".*;
    var a2 = "--user".*;
    var a3 = "vic".*;
    var a4 = "stray".*;
    var argv: [5][:0]u8 = .{ a0[0..], a1[0..], a2[0..], a3[0..], a4[0..] };
    try std.testing.expectError(ArgError.UnexpectedPositional, parseArgs(&argv));
}

test "parseArgs accepts --launch with --user and --session" {
    var a0 = "pgsd-sessiond".*;
    var a1 = "--launch".*;
    var a2 = "--user".*;
    var a3 = "vic".*;
    var a4 = "--session".*;
    var a5 = "default".*;
    var argv: [6][:0]u8 = .{ a0[0..], a1[0..], a2[0..], a3[0..], a4[0..], a5[0..] };
    const args = try parseArgs(&argv);
    try std.testing.expect(args.launch);
    try std.testing.expectEqualStrings("vic", args.user.?);
    try std.testing.expectEqualStrings("default", args.session.?);
}

test "parseArgs accepts --launch with --user= and --session= forms" {
    var a0 = "pgsd-sessiond".*;
    var a1 = "--launch".*;
    var a2 = "--user=vic".*;
    var a3 = "--session=default".*;
    var argv: [4][:0]u8 = .{ a0[0..], a1[0..], a2[0..], a3[0..] };
    const args = try parseArgs(&argv);
    try std.testing.expect(args.launch);
    try std.testing.expectEqualStrings("vic", args.user.?);
    try std.testing.expectEqualStrings("default", args.session.?);
}

test "parseArgs rejects --launch without --session" {
    var a0 = "pgsd-sessiond".*;
    var a1 = "--launch".*;
    var a2 = "--user".*;
    var a3 = "vic".*;
    var argv: [4][:0]u8 = .{ a0[0..], a1[0..], a2[0..], a3[0..] };
    try std.testing.expectError(ArgError.MissingSession, parseArgs(&argv));
}

test "parseArgs rejects --launch without --user" {
    var a0 = "pgsd-sessiond".*;
    var a1 = "--launch".*;
    var a2 = "--session".*;
    var a3 = "default".*;
    var argv: [4][:0]u8 = .{ a0[0..], a1[0..], a2[0..], a3[0..] };
    try std.testing.expectError(ArgError.MissingUser, parseArgs(&argv));
}

test "parseArgs rejects --launch combined with --auth-test" {
    var a0 = "pgsd-sessiond".*;
    var a1 = "--launch".*;
    var a2 = "--auth-test".*;
    var a3 = "--user".*;
    var a4 = "vic".*;
    var a5 = "--session".*;
    var a6 = "default".*;
    var argv: [7][:0]u8 = .{ a0[0..], a1[0..], a2[0..], a3[0..], a4[0..], a5[0..], a6[0..] };
    try std.testing.expectError(ArgError.MultipleModesSelected, parseArgs(&argv));
}

test "parseArgs rejects --session without a value" {
    var a0 = "pgsd-sessiond".*;
    var a1 = "--launch".*;
    var a2 = "--user".*;
    var a3 = "vic".*;
    var a4 = "--session".*;
    var argv: [5][:0]u8 = .{ a0[0..], a1[0..], a2[0..], a3[0..], a4[0..] };
    try std.testing.expectError(ArgError.MissingSessionValue, parseArgs(&argv));
}

test "parseArgs accepts --list-sessions alone" {
    var a0 = "pgsd-sessiond".*;
    var a1 = "--list-sessions".*;
    var argv: [2][:0]u8 = .{ a0[0..], a1[0..] };
    const args = try parseArgs(&argv);
    try std.testing.expect(args.list_sessions);
    try std.testing.expect(!args.auth_test);
    try std.testing.expect(!args.list_users);
    try std.testing.expect(!args.launch);
}

test "parseArgs rejects --list-sessions combined with --launch" {
    var a0 = "pgsd-sessiond".*;
    var a1 = "--list-sessions".*;
    var a2 = "--launch".*;
    var a3 = "--user".*;
    var a4 = "vic".*;
    var a5 = "--session".*;
    var a6 = "default".*;
    var argv: [7][:0]u8 = .{ a0[0..], a1[0..], a2[0..], a3[0..], a4[0..], a5[0..], a6[0..] };
    try std.testing.expectError(ArgError.MultipleModesSelected, parseArgs(&argv));
}

test "parseArgs rejects --list-sessions combined with --list-users" {
    var a0 = "pgsd-sessiond".*;
    var a1 = "--list-sessions".*;
    var a2 = "--list-users".*;
    var argv: [3][:0]u8 = .{ a0[0..], a1[0..], a2[0..] };
    try std.testing.expectError(ArgError.MultipleModesSelected, parseArgs(&argv));
}
