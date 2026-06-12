// pgsd-sessiond/src/pam.zig
//
// Thin Zig wrapper around FreeBSD's libpam (OpenPAM).
//
// Stage 1 scope: cover the PAM primitives needed to authenticate a
// user and confirm the account is valid. That is:
//
//   - pam_start / pam_end (transaction lifecycle).
//   - pam_authenticate (verify credentials).
//   - pam_acct_mgmt (check account expiry / login.access / pam_nologin).
//   - pam_strerror (turn return codes into human-readable messages).
//   - pam_get_item (retrieve PAM_USER after auth).
//   - A Conversation interface that bridges the C callback to a Zig
//     callback.
//
// Stage 3 adds the session-management primitives:
//
//   - pam_setcred (establish or delete credentials).
//   - pam_open_session / pam_close_session (session lifecycle).
//   - pam_getenvlist (retrieve PAM-contributed environment variables).
//
// All PAM return codes are translated to Zig errors. The original PAM_*
// integer codes are exposed as `Error` variants so callers can
// distinguish auth failure from user-unknown from system error.
//
// The wrapper is FreeBSD-specific: it links libpam (-lpam, the
// OpenPAM implementation in FreeBSD base) and assumes OpenPAM
// semantics. Portability to Linux-PAM is not a goal.

const std = @import("std");

const c = @cImport({
    @cInclude("security/pam_appl.h");
});

// =============================================================================
// PAM message style and return-code aliases
// =============================================================================
//
// We alias values from the libpam header rather than hardcoding the
// numeric constants. OpenPAM's pam_constants.h is the authoritative
// source; hardcoding would risk a value drift between FreeBSD versions.

pub const PROMPT_ECHO_OFF: c_int = c.PAM_PROMPT_ECHO_OFF;
pub const PROMPT_ECHO_ON: c_int = c.PAM_PROMPT_ECHO_ON;
pub const ERROR_MSG: c_int = c.PAM_ERROR_MSG;
pub const TEXT_INFO: c_int = c.PAM_TEXT_INFO;

pub const PAM_SUCCESS: c_int = c.PAM_SUCCESS;

// Setcred flags used in stage 3.
pub const ESTABLISH_CRED: c_int = c.PAM_ESTABLISH_CRED;
pub const DELETE_CRED: c_int = c.PAM_DELETE_CRED;

// =============================================================================
// Errors
// =============================================================================

pub const Error = error{
    AuthFailed, // PAM_AUTH_ERR / PAM_CRED_INSUFFICIENT
    UserUnknown, // PAM_USER_UNKNOWN
    MaxTries, // PAM_MAXTRIES
    NewAuthTokRequired, // PAM_NEW_AUTHTOK_REQD (password expired)
    AccountExpired, // PAM_ACCT_EXPIRED
    PermDenied, // PAM_PERM_DENIED
    Aborted, // PAM_ABORT (caller aborted, e.g. via conversation)
    ServiceError, // PAM_SERVICE_ERR (broken /etc/pam.d/ entry)
    SystemError, // PAM_SYSTEM_ERR / PAM_BUF_ERR / PAM_OPEN_ERR
    ConvError, // PAM_CONV_ERR (conversation function failed)
    Unknown,
};

fn errorFromCode(code: c_int) Error {
    return switch (code) {
        c.PAM_AUTH_ERR, c.PAM_CRED_INSUFFICIENT => Error.AuthFailed,
        c.PAM_USER_UNKNOWN => Error.UserUnknown,
        c.PAM_MAXTRIES => Error.MaxTries,
        c.PAM_NEW_AUTHTOK_REQD => Error.NewAuthTokRequired,
        c.PAM_ACCT_EXPIRED => Error.AccountExpired,
        c.PAM_PERM_DENIED => Error.PermDenied,
        c.PAM_ABORT => Error.Aborted,
        c.PAM_SERVICE_ERR => Error.ServiceError,
        c.PAM_SYSTEM_ERR, c.PAM_BUF_ERR, c.PAM_OPEN_ERR => Error.SystemError,
        c.PAM_CONV_ERR => Error.ConvError,
        else => Error.Unknown,
    };
}

fn check(code: c_int) Error!void {
    if (code == PAM_SUCCESS) return;
    return errorFromCode(code);
}

// =============================================================================
// Conversation interface
// =============================================================================
//
// The application provides a Conversation. The PAM library calls into it
// once per prompt. `respond` receives the prompt text and the message style
// (PROMPT_ECHO_OFF, PROMPT_ECHO_ON, ERROR_MSG, TEXT_INFO).
//
// For prompts (PROMPT_ECHO_*), `respond` must return a malloc-allocated
// null-terminated string. libpam takes ownership and frees it via free(3).
//
// For messages (ERROR_MSG, TEXT_INFO), `respond` should return null;
// libpam does not consume responses for those styles.
//
// If `respond` returns an error, the PAM transaction aborts with
// PAM_CONV_ERR.

pub const Conversation = struct {
    ctx: *anyopaque,
    respond_fn: *const fn (
        ctx: *anyopaque,
        style: c_int,
        prompt: []const u8,
    ) anyerror!?[*:0]u8,

    pub fn respond(
        self: *const Conversation,
        style: c_int,
        prompt: []const u8,
    ) anyerror!?[*:0]u8 {
        return self.respond_fn(self.ctx, style, prompt);
    }
};

// The C-side trampoline. libpam calls this with appdata_ptr set to a
// *Conversation; we dispatch to the Zig respond callback.
fn convTrampoline(
    num_msg: c_int,
    msg: [*c][*c]const c.struct_pam_message,
    resp_out: [*c][*c]c.struct_pam_response,
    appdata_ptr: ?*anyopaque,
) callconv(.c) c_int {
    if (num_msg <= 0 or appdata_ptr == null or msg == null or resp_out == null) {
        return c.PAM_BUF_ERR;
    }
    const conv: *const Conversation = @ptrCast(@alignCast(appdata_ptr.?));
    const n: usize = @intCast(num_msg);

    // Allocate response array with malloc(3); libpam frees it.
    const resp_size = @sizeOf(c.struct_pam_response) * n;
    const raw = std.c.malloc(resp_size) orelse return c.PAM_BUF_ERR;
    @memset(@as([*]u8, @ptrCast(raw))[0..resp_size], 0);
    const responses: [*]c.struct_pam_response = @ptrCast(@alignCast(raw));

    var i: usize = 0;
    while (i < n) : (i += 1) {
        const m = msg[i];
        if (m == null) {
            freeResponses(raw, responses, i);
            return c.PAM_BUF_ERR;
        }
        const style = m.*.msg_style;
        const prompt_c = m.*.msg;
        const prompt_slice: []const u8 = blk: {
            if (prompt_c == null) break :blk &[_]u8{};
            const cstr: [*:0]const u8 = @ptrCast(prompt_c);
            const len = std.mem.len(cstr);
            break :blk cstr[0..len];
        };

        const reply = conv.respond(style, prompt_slice) catch {
            freeResponses(raw, responses, i);
            return c.PAM_CONV_ERR;
        };

        responses[i].resp = if (reply) |s| s else null;
        responses[i].resp_retcode = 0;
    }

    resp_out.* = responses;
    return c.PAM_SUCCESS;
}

// Free responses[0..count] before bailing on a partial conversation.
fn freeResponses(
    raw: *anyopaque,
    responses: [*]c.struct_pam_response,
    count: usize,
) void {
    var j: usize = 0;
    while (j < count) : (j += 1) {
        if (responses[j].resp != null) std.c.free(responses[j].resp);
    }
    std.c.free(raw);
}

// =============================================================================
// Pam: the transaction handle
// =============================================================================

pub const Pam = struct {
    handle: ?*c.pam_handle_t = null,
    // We keep the pam_conv struct in the Pam itself so it lives as long
    // as the handle does. libpam stores a pointer to it.
    pam_conv_storage: c.struct_pam_conv = .{
        .conv = null,
        .appdata_ptr = null,
    },

    /// Begin a PAM transaction.
    ///
    /// `service` names a file in /etc/pam.d/. For pgsd-sessiond stage 1
    /// the caller passes "pgsd-sessiond" (falling back to "login" if the
    /// pgsd-sessiond service file isn't installed yet).
    ///
    /// `user` is the target username, or null to defer to pam_authenticate
    /// (which will then prompt via the conversation).
    ///
    /// `conv` must outlive the Pam handle.
    pub fn start(
        self: *Pam,
        service: [:0]const u8,
        user: ?[:0]const u8,
        conv: *const Conversation,
    ) Error!void {
        self.pam_conv_storage.conv = convTrampoline;
        self.pam_conv_storage.appdata_ptr = @constCast(@ptrCast(conv));

        const user_c: ?[*:0]const u8 = if (user) |u| u.ptr else null;

        const rc = c.pam_start(
            service.ptr,
            user_c,
            &self.pam_conv_storage,
            &self.handle,
        );
        try check(rc);
    }

    /// Run the authentication chain. The conversation function will be
    /// invoked one or more times to gather credentials.
    pub fn authenticate(self: *Pam) Error!void {
        if (self.handle == null) return Error.SystemError;
        const rc = c.pam_authenticate(self.handle, 0);
        try check(rc);
    }

    /// Run the account-management chain. Checks for account expiry,
    /// /var/run/nologin, /etc/login.access restrictions, etc. Returns
    /// AuthFailed/AccountExpired/etc. on rejection.
    pub fn acctMgmt(self: *Pam) Error!void {
        if (self.handle == null) return Error.SystemError;
        const rc = c.pam_acct_mgmt(self.handle, 0);
        try check(rc);
    }

    /// Set or clear credentials on the PAM handle.
    ///
    /// `flags` is one of ESTABLISH_CRED (after successful authentication,
    /// before opening the session) or DELETE_CRED (after closing the
    /// session, before pam_end). Other flag values (REINITIALIZE_CRED,
    /// REFRESH_CRED) are accepted by libpam but not used by pgsd-sessiond.
    pub fn setcred(self: *Pam, flags: c_int) Error!void {
        if (self.handle == null) return Error.SystemError;
        const rc = c.pam_setcred(self.handle, flags);
        try check(rc);
    }

    /// Open a PAM session. Must be called after successful
    /// authenticate(), acctMgmt(), and setcred(ESTABLISH_CRED), and
    /// before any privilege drop. Session-open modules update utmp/wtmp,
    /// may populate the env list, and perform other per-session setup.
    pub fn openSession(self: *Pam) Error!void {
        if (self.handle == null) return Error.SystemError;
        const rc = c.pam_open_session(self.handle, 0);
        try check(rc);
    }

    /// Close a PAM session. Called once the session leader has exited,
    /// while the daemon is still root. Pairs with openSession().
    pub fn closeSession(self: *Pam) Error!void {
        if (self.handle == null) return Error.SystemError;
        const rc = c.pam_close_session(self.handle, 0);
        try check(rc);
    }

    /// Retrieve the PAM-contributed environment list, copied into Zig
    /// allocations. Caller owns the returned slice; deinit with
    /// freeEnvList(). Common contributors: pam_krb5 (KRB5CCNAME),
    /// pam_ssh (SSH_AUTH_SOCK), pam_env (operator-defined vars).
    ///
    /// Each returned slice is a NUL-terminated "KEY=VALUE" string; the
    /// terminating NUL is not included in the slice length.
    ///
    /// If libpam has no env contributions for this transaction,
    /// pam_getenvlist returns NULL; we treat that as an empty list and
    /// return a zero-length slice, not an error.
    ///
    /// The return type unions pam.Error with allocator errors because
    /// the per-entry dupe calls can OOM independently of any PAM
    /// failure.
    pub fn getEnvList(
        self: *Pam,
        allocator: std.mem.Allocator,
    ) (Error || std.mem.Allocator.Error)![][]u8 {
        if (self.handle == null) return Error.SystemError;
        // pam_getenvlist returns a malloc'd NULL-terminated array of
        // malloc'd "KEY=VALUE" strings. The caller must free both the
        // strings and the array via free(3). We copy into Zig-owned
        // allocations and free the libpam structures immediately.
        //
        // NULL return means an empty list (e.g. no PAM modules
        // contributed env vars). Return a zero-length slice rather
        // than treating NULL as an error.
        const raw = c.pam_getenvlist(self.handle);
        if (raw == null) return try allocator.alloc([]u8, 0);
        defer std.c.free(@ptrCast(raw));

        // First pass: count entries.
        var count: usize = 0;
        while (raw[count] != null) : (count += 1) {}

        // Allocate the Zig slice-of-slices. On error, free what we've
        // copied so far plus the remaining libpam strings.
        var result = try allocator.alloc([]u8, count);
        var copied: usize = 0;
        errdefer {
            var k: usize = 0;
            while (k < copied) : (k += 1) allocator.free(result[k]);
            allocator.free(result);
            // Free remaining libpam strings we didn't copy.
            var m: usize = copied;
            while (raw[m] != null) : (m += 1) std.c.free(@ptrCast(raw[m].?));
        }

        var i: usize = 0;
        while (i < count) : (i += 1) {
            const entry_cstr: [*:0]const u8 = @ptrCast(raw[i].?);
            const entry = std.mem.span(entry_cstr);
            result[i] = try allocator.dupe(u8, entry);
            copied += 1;
            std.c.free(@ptrCast(raw[i].?));
        }

        return result;
    }

    /// Free a slice returned by getEnvList().
    pub fn freeEnvList(allocator: std.mem.Allocator, list: [][]u8) void {
        for (list) |entry| allocator.free(entry);
        allocator.free(list);
    }

    /// Retrieve the PAM_USER item. After successful authenticate(), this
    /// is the authenticated username (which may differ from what was
    /// passed to start() if the conversation prompted for it).
    pub fn getUser(self: *Pam) Error![]const u8 {
        if (self.handle == null) return Error.SystemError;
        var ptr: ?*const anyopaque = null;
        const rc = c.pam_get_item(self.handle, c.PAM_USER, &ptr);
        try check(rc);
        if (ptr == null) return Error.SystemError;
        const cstr: [*:0]const u8 = @ptrCast(ptr.?);
        return std.mem.span(cstr);
    }

    /// Get a human-readable description of a PAM error code. The returned
    /// slice is valid until the next PAM call on this handle.
    pub fn strerror(self: *Pam, code: c_int) []const u8 {
        if (self.handle == null) return "no PAM handle";
        const cstr = c.pam_strerror(self.handle, code);
        if (cstr == null) return "unknown";
        return std.mem.span(@as([*:0]const u8, @ptrCast(cstr)));
    }

    /// Tear down the transaction. Always safe to call; idempotent.
    pub fn end(self: *Pam, status: c_int) void {
        if (self.handle != null) {
            _ = c.pam_end(self.handle, status);
            self.handle = null;
        }
    }
};

// =============================================================================
// Tests
// =============================================================================
//
// The unit tests do not invoke real PAM auth (that would require a live
// system password and stdin). Instead they exercise the Conversation
// trampoline directly with a mock callback, verifying that the malloc /
// free dance works and that errors propagate.

test "conversation trampoline allocates and frees response correctly" {
    const TestCtx = struct {
        called_with_style: c_int = -1,
        called_with_prompt: []const u8 = "",

        fn respond(
            ctx: *anyopaque,
            style: c_int,
            prompt: []const u8,
        ) anyerror!?[*:0]u8 {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.called_with_style = style;
            self.called_with_prompt = prompt;

            // Allocate a response via malloc (libpam will free).
            const reply_text = "the_password\x00";
            const buf = std.c.malloc(reply_text.len) orelse return error.OutOfMemory;
            @memcpy(@as([*]u8, @ptrCast(buf))[0..reply_text.len], reply_text);
            return @ptrCast(buf);
        }
    };

    var ctx = TestCtx{};
    const conv = Conversation{
        .ctx = &ctx,
        .respond_fn = TestCtx.respond,
    };

    // Construct a fake pam_message for the trampoline.
    var msg = c.struct_pam_message{
        .msg_style = PROMPT_ECHO_OFF,
        .msg = @constCast("Password:"),
    };
    var msg_ptr: [*c]const c.struct_pam_message = &msg;
    var responses: [*c]c.struct_pam_response = null;

    const rc = convTrampoline(1, @ptrCast(&msg_ptr), &responses, @constCast(@ptrCast(&conv)));
    try std.testing.expectEqual(@as(c_int, c.PAM_SUCCESS), rc);
    try std.testing.expectEqual(PROMPT_ECHO_OFF, ctx.called_with_style);
    try std.testing.expectEqualStrings("Password:", ctx.called_with_prompt);

    // Verify the response was populated.
    try std.testing.expect(responses != null);
    try std.testing.expect(responses[0].resp != null);
    const reply_cstr: [*:0]const u8 = @ptrCast(responses[0].resp);
    try std.testing.expectEqualStrings("the_password", std.mem.span(reply_cstr));

    // Simulate libpam freeing the response (which it would do after use).
    std.c.free(responses[0].resp);
    std.c.free(responses);
}

test "conversation trampoline propagates conv-callback errors" {
    const TestCtx = struct {
        fn respond(
            ctx: *anyopaque,
            style: c_int,
            prompt: []const u8,
        ) anyerror!?[*:0]u8 {
            _ = ctx;
            _ = style;
            _ = prompt;
            return error.SimulatedFailure;
        }
    };

    var dummy: u8 = 0;
    const conv = Conversation{
        .ctx = @ptrCast(&dummy),
        .respond_fn = TestCtx.respond,
    };

    var msg = c.struct_pam_message{
        .msg_style = PROMPT_ECHO_OFF,
        .msg = @constCast("Password:"),
    };
    var msg_ptr: [*c]const c.struct_pam_message = &msg;
    var responses: [*c]c.struct_pam_response = null;

    const rc = convTrampoline(1, @ptrCast(&msg_ptr), &responses, @constCast(@ptrCast(&conv)));
    try std.testing.expectEqual(@as(c_int, c.PAM_CONV_ERR), rc);
    // responses must not have been populated on error.
    try std.testing.expect(responses == null);
}

test "conversation trampoline rejects null appdata" {
    var msg = c.struct_pam_message{
        .msg_style = PROMPT_ECHO_OFF,
        .msg = @constCast("Password:"),
    };
    var msg_ptr: [*c]const c.struct_pam_message = &msg;
    var responses: [*c]c.struct_pam_response = null;

    const rc = convTrampoline(1, @ptrCast(&msg_ptr), &responses, null);
    try std.testing.expectEqual(@as(c_int, c.PAM_BUF_ERR), rc);
}

test "conversation trampoline rejects zero num_msg" {
    var dummy: u8 = 0;
    const conv = Conversation{
        .ctx = @ptrCast(&dummy),
        .respond_fn = undefined,
    };
    var msg_ptr: [*c]const c.struct_pam_message = null;
    var responses: [*c]c.struct_pam_response = null;

    const rc = convTrampoline(0, @ptrCast(&msg_ptr), &responses, @constCast(@ptrCast(&conv)));
    try std.testing.expectEqual(@as(c_int, c.PAM_BUF_ERR), rc);
}

test "errorFromCode maps known codes" {
    try std.testing.expectEqual(Error.AuthFailed, errorFromCode(c.PAM_AUTH_ERR));
    try std.testing.expectEqual(Error.UserUnknown, errorFromCode(c.PAM_USER_UNKNOWN));
    try std.testing.expectEqual(Error.MaxTries, errorFromCode(c.PAM_MAXTRIES));
    try std.testing.expectEqual(Error.ServiceError, errorFromCode(c.PAM_SERVICE_ERR));
    try std.testing.expectEqual(Error.ConvError, errorFromCode(c.PAM_CONV_ERR));
    try std.testing.expectEqual(Error.Unknown, errorFromCode(9999));
}

test "check propagates success and failure" {
    try check(c.PAM_SUCCESS);
    try std.testing.expectError(Error.AuthFailed, check(c.PAM_AUTH_ERR));
    try std.testing.expectError(Error.UserUnknown, check(c.PAM_USER_UNKNOWN));
}
