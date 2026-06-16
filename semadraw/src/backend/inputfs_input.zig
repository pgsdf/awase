//! inputfs_input.zig: drains the inputfs event ring and translates
//! events into the drawfs backend's KeyEvent and MouseEvent buffers.
//!
//! Replaces the legacy DRAWFSGIOC_INJECT_INPUT path that semainputd
//! used to push events through. inputfs publishes events directly to
//! /var/run/sema/input/events (per shared/INPUT_EVENTS.md and
//! shared/src/input.zig); this adapter consumes them.
//!
//! AD-2a Phase 1: this is the userland half of the cutover. The legacy
//! injection path remains in place but unconsumed; semainputd may
//! continue running but its events are ignored. Phase 3 deletes the
//! legacy paths.

const std = @import("std");
const backend = @import("backend");
const input = @import("input");
const translate = @import("inputfs_translate.zig");

// ADR 0009: FreeBSD kqueue ABI constants, stone-stable since the
// interface's introduction; defined locally to avoid std.c naming
// drift across Zig releases.
const EVFILT_READ: i16 = -1;
const EV_ADD: u16 = 0x0001;
const EV_CLEAR: u16 = 0x0020;

const log = std.log.scoped(.inputfs_input);

// ============================================================================
// inputfs event_type constants for source_role = SOURCE_KEYBOARD / SOURCE_POINTER
// ============================================================================

// Per shared/INPUT_EVENTS.md §"Event types and payload layouts".

const KEYBOARD_KEY_DOWN: u8 = 1;
const KEYBOARD_KEY_UP: u8 = 2;

// Pointer event_type constants now live in shared/src/input.zig
// as input.POINTER_MOTION etc. (AD-2a Phase 3 cleanup; previously
// duplicated here and in semadrawd.zig). Use input.POINTER_* at
// call sites.
// 5 = enter, 6 = leave: synthesised by inputfs Stage D; not consumed
// by Phase 1 (the drawfs backend models enter/leave implicitly via
// the active surface).

// Pointer button bitmask (HID-style; matches what inputfs publishes).
const BUTTON_LEFT: u32 = 0x1;
const BUTTON_RIGHT: u32 = 0x2;
const BUTTON_MIDDLE: u32 = 0x4;

// Drain batch size. Bounded to keep the per-frame work predictable;
// at 60Hz with one event per ms this is enough headroom for a full
// keyboard rollover plus pointer activity in any single frame.
//
// Public so callers (drawfs.zig) can size the side-channel buffer
// to match the drain capacity, ensuring no events drop on the
// per-call boundary.
pub const DRAIN_BATCH: usize = 64;

// ============================================================================
// InputfsInput
// ============================================================================

pub const InputfsInput = struct {
    reader: input.EventRingReader,
    /// last_modifiers tracks the most recent modifier bitmask seen
    /// from a keyboard event. Mouse events from inputfs do not carry
    /// modifier state; the backend's MouseEvent type does. Carry-
    /// forward is the simplest faithful behaviour (matches what
    /// semainputd was doing implicitly).
    last_modifiers: u8,
    /// AD-41.3: file descriptor for /dev/inputfs_notify, opened
    /// purely as a poll/kqueue wake source. Null if the cdev was
    /// absent at init time (older inputfs build, module unloaded,
    /// or insufficient permissions to open). Consumers fall back
    /// to the poll-timeout-based drain cadence when null.
    ///
    /// See inputfs/docs/adr/0021 and BACKLOG AD-41 for the
    /// architecture. The notify fd carries no data; reads return
    /// EOPNOTSUPP and the consumer must mmap the events region
    /// (already managed by `reader` above) to drain published
    /// events.
    notify_fd: ?std.posix.fd_t,

    /// ADR 0009: the kqueue bridge. The notify cdev's d_poll is
    /// edge-only and can never deliver POLLIN through poll(2)
    /// (selwakeup triggers a rescan, d_poll returns 0 again, the
    /// kernel resumes sleeping); only the cdev's kqueue path
    /// reports readiness correctly. This kqueue holds one knote,
    /// the notify fd registered EVFILT_READ with EV_CLEAR, and the
    /// kqueue's own descriptor is what semadrawd polls: kqueue fds
    /// are pollable and go readable when a registered knote fires.
    /// Null when the notify cdev is absent or bridge setup failed;
    /// the caller falls back to poll-timeout cadence.
    wake_kq: ?std.posix.fd_t,

    const Self = @This();

    /// Open the inputfs event ring and skip to the current writer
    /// position so historical events are not replayed at startup.
    /// Returns null on any open or validation failure; caller treats
    /// null as "inputfs not available" and proceeds without input
    /// from this source. inputfs may not be loaded; the compositor
    /// must not refuse to start because of it.
    ///
    /// `quiet` suppresses the per-attempt warn logging. The first
    /// probe at backend init passes quiet=false so a genuinely
    /// absent inputfs is reported once, loudly. The throttled retry
    /// path (AD-2a: inputfs publishes its ring asynchronously and
    /// may not be ready when semadrawd first probes at boot) passes
    /// quiet=true so a ring that is merely "not published yet" does
    /// not flood the log once per second until it appears. The
    /// success path always logs (info) regardless of `quiet`, so a
    /// late latch is visible on the bench.
    ///
    /// AD-41.3: also opens /dev/inputfs_notify if available. The
    /// notify open is independent of the ring open: a successfully
    /// opened ring with an absent notify cdev still returns a
    /// usable InputfsInput. The notify fd is only consulted by
    /// semadrawd's poll() set; the ring drain path does not use it.
    pub fn init(quiet: bool) ?Self {
        var reader = input.EventRingReader.init(input.EVENTS_PATH);
        if (reader.map == null) {
            if (!quiet) {
                log.warn("inputfs ring at {s} unavailable; no input from inputfs", .{input.EVENTS_PATH});
            }
            return null;
        }
        if (!reader.isValid()) {
            if (!quiet) {
                log.warn("inputfs ring at {s} not valid; no input from inputfs", .{input.EVENTS_PATH});
            }
            reader.deinit();
            return null;
        }

        // Skip historical events. The reader's last_consumed starts
        // at 0; setting it to writer_seq means the first drain returns
        // only events published after this point. This is what makes
        // a LATE successful attach safe: a retry that latches long
        // after boot starts from "now", not from a replay of every
        // keystroke buffered since the ring was created.
        reader.last_consumed = reader.writerSeq();

        log.info("inputfs ring opened, starting from seq {}", .{reader.last_consumed});

        // AD-41.3: open /dev/inputfs_notify as the wake source.
        // Best-effort: a missing cdev (older inputfs without
        // AD-41.3) or perms failure leaves notify_fd null. We log
        // a single info line either way so the bench-side state
        // is visible at startup.
        const notify_fd: ?std.posix.fd_t = blk: {
            const f = std.fs.openFileAbsolute(input.NOTIFY_DEV_PATH, .{}) catch |err| {
                if (!quiet) {
                    log.warn("inputfs notify cdev at {s} unavailable: {}; falling back to poll-timeout cadence", .{ input.NOTIFY_DEV_PATH, err });
                }
                break :blk null;
            };
            log.info("inputfs notify cdev opened at {s} (fd={})", .{ input.NOTIFY_DEV_PATH, f.handle });
            break :blk f.handle;
        };

        // ADR 0009: build the kqueue bridge over the notify fd.
        // Best-effort like the open above: any failure logs once
        // and leaves wake_kq null (poll-timeout cadence).
        const wake_kq: ?std.posix.fd_t = blk: {
            const nfd = notify_fd orelse break :blk null;
            const kq = std.posix.kqueue() catch |err| {
                if (!quiet) log.warn("kqueue bridge unavailable: {}; falling back to poll-timeout cadence", .{err});
                break :blk null;
            };
            var changes = [1]std.posix.Kevent{std.mem.zeroes(std.posix.Kevent)};
            changes[0].ident = @intCast(nfd);
            changes[0].filter = EVFILT_READ;
            changes[0].flags = EV_ADD | EV_CLEAR;
            _ = std.posix.kevent(kq, &changes, &.{}, null) catch |err| {
                if (!quiet) log.warn("kqueue bridge registration failed: {}; falling back to poll-timeout cadence", .{err});
                closeFd(kq);
                break :blk null;
            };
            log.info("inputfs wake bridge: notify fd {} registered in kqueue fd {} (EVFILT_READ, EV_CLEAR)", .{ nfd, kq });
            break :blk kq;
        };

        return .{
            .reader = reader,
            .last_modifiers = 0,
            .notify_fd = notify_fd,
            .wake_kq = wake_kq,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.wake_kq) |kq| {
            closeFd(kq);
            self.wake_kq = null;
        }
        if (self.notify_fd) |fd| {
            closeFd(fd);
            self.notify_fd = null;
        }
        self.reader.deinit();
    }

    /// AD-41.3: return the notify cdev's fd, if open. semadrawd
    /// adds this to its poll() set so the main loop wakes
    /// immediately on inputfs event publication instead of
    /// waiting out the 100 ms fallback timeout. Null means the
    /// cdev was unavailable at init time; the caller should not
    /// add anything to the poll set in that case.
    pub fn getNotifyFd(self: *const Self) ?std.posix.fd_t {
        return self.notify_fd;
    }

    /// ADR 0009: the pollable wake descriptor, the kqueue fd, or
    /// null when the bridge is absent. This, not the raw notify
    /// fd, is what belongs in semadrawd's poll set.
    pub fn getWakeFd(self: *const Self) ?std.posix.fd_t {
        return self.wake_kq;
    }

    /// ADR 0009: consume pending kevents so the kqueue fd's
    /// readiness clears (EV_CLEAR re-arms the knote on this read).
    /// Per the AD-32 rule, this is the wake fd's dispatch-path
    /// drain handler; the event-ring harvest itself runs in the
    /// existing per-pass path and is not duplicated here. Errors
    /// are swallowed: a lost wake costs at most one poll timeout.
    pub fn drainWake(self: *Self) void {
        const kq = self.wake_kq orelse return;
        var evs: [4]std.posix.Kevent = undefined;
        const zero = std.mem.zeroes(std.posix.timespec);
        _ = std.posix.kevent(kq, &.{}, &evs, &zero) catch return;
    }

    /// Drain all newly published events from the inputfs ring and
    /// dispatch them into the provided KeyEvent and MouseEvent
    /// stash buffers. Caller is responsible for resetting the
    /// stash buffers after consumption (matches the existing
    /// drawfs backend convention; see getKeyEventsImpl).
    ///
    /// AD-2a Phase 2.4.2: every drained `input.Event` is also
    /// appended to `inputfs_events` (up to its capacity) BEFORE
    /// dispatch is called, so touch and pen events, which
    /// `dispatch` drops via its `else => return` arm, still reach
    /// the side-channel. semadrawd's main loop reads this buffer in
    /// Phase 2.4.4 to feed the gesture recogniser, which needs the
    /// device_slot field that translated MouseEvents don't carry.
    /// Until 2.4.4 lands, the buffer fills and drains harmlessly
    /// with no consumer.
    ///
    /// Returns the count of events drained from the ring (not the
    /// count appended to the buffers; some inputfs events do not
    /// produce backend events, e.g. MOTION with dx==0 dy==0).
    pub fn drain(
        self: *Self,
        keys: []backend.KeyEvent,
        keys_len: *usize,
        mice: []backend.MouseEvent,
        mice_len: *usize,
        inputfs_events: []input.Event,
        inputfs_events_len: *usize,
    ) usize {
        var batch: [DRAIN_BATCH]input.Event = undefined;
        const result = self.reader.drain(&batch) catch |err| switch (err) {
            error.NotOpen => return 0,
        };

        if (result.overrun) {
            log.warn("inputfs ring overrun; some events lost", .{});
            // last_consumed has been repositioned by the reader;
            // continue with the new batch.
        }

        const events = batch[0..result.events_consumed];
        for (events) |ev| {
            // Side-channel: append every raw event before dispatch.
            // The append must happen here (not in dispatch) because
            // dispatch's `else => return` arm drops touch and pen
            // events; the recogniser needs them for multi-touch
            // gestures (pinch, two-finger scroll, three-finger
            // swipe).
            if (inputfs_events_len.* < inputfs_events.len) {
                inputfs_events[inputfs_events_len.*] = ev;
                inputfs_events_len.* += 1;
            }
            // Existing typed-event flow unchanged.
            self.dispatch(ev, keys, keys_len, mice, mice_len);
        }
        return result.events_consumed;
    }

    fn dispatch(
        self: *Self,
        ev: input.Event,
        keys: []backend.KeyEvent,
        keys_len: *usize,
        mice: []backend.MouseEvent,
        mice_len: *usize,
    ) void {
        switch (ev.source_role) {
            input.SOURCE_KEYBOARD => self.dispatchKeyboard(ev, keys, keys_len),
            input.SOURCE_POINTER => self.dispatchPointer(ev, mice, mice_len),
            // Touch (3), pen (4), lighting (5), device-lifecycle (6):
            // not consumed by Phase 1. Touch and pen are deferred per
            // AD-1's Status block; the others are not relevant to
            // KeyEvent/MouseEvent forwarding.
            else => return,
        }
    }

    // ------------------------------------------------------------------------
    // Keyboard dispatch
    // ------------------------------------------------------------------------

    fn dispatchKeyboard(
        self: *Self,
        ev: input.Event,
        keys: []backend.KeyEvent,
        keys_len: *usize,
    ) void {
        // Payload (per INPUT_EVENTS.md §Keyboard, source_role=2):
        //   hid_usage(u32 0-3), positional(u32 4-7),
        //   modifiers(u32 8-11), session_id(u32 12-15)
        //
        // The modifier byte at offset 8 is the raw HID Boot Keyboard
        // modifier byte (USB HID spec §10): bit 0 = LCtrl, bit 1 = LShift,
        // bit 2 = LAlt, bit 3 = LMeta, bits 4-7 are the corresponding
        // right-side modifiers. The backend KeyEvent.modifiers field uses
        // a different layout: bit 0 = Shift, bit 1 = Alt, bit 2 = Ctrl,
        // bit 3 = Meta. translate.hidModifiersToBackend handles the
        // bit reordering and folds left/right pairs together. Pre-fix
        // (this commit) the raw HID byte was forwarded directly,
        // making every modifier register as the wrong key (Alt+N
        // arrived as Ctrl+N at the client; semadraw-term's
        // session-switch handler never saw an actual ALT bit).
        const hid_usage = std.mem.readInt(u32, ev.payload[0..4], .little);
        const hid_modifiers = @as(u8, @truncate(std.mem.readInt(u32, ev.payload[8..12], .little)));
        const modifiers = translate.hidModifiersToBackend(hid_modifiers);
        // session_id at offset 12 dropped on the floor in Phase 1
        // (single-session model; whatever inputfs routes to is "us").

        const evdev_code = translate.hidUsageToEvdev(hid_usage);
        if (evdev_code == 0) {
            // Unmapped HID usage. Drop rather than forward as
            // key_code = 0; clients consume key_code as authoritative.
            return;
        }

        const pressed = switch (ev.event_type) {
            KEYBOARD_KEY_DOWN => true,
            KEYBOARD_KEY_UP => false,
            else => return, // unknown event_type per spec §Failure modes: skip
        };

        self.last_modifiers = modifiers;

        if (keys_len.* >= keys.len) return; // buffer full, drop
        keys[keys_len.*] = .{
            .key_code = evdev_code,
            .modifiers = modifiers,
            .pressed = pressed,
        };
        keys_len.* += 1;
    }

    // ------------------------------------------------------------------------
    // Pointer dispatch
    // ------------------------------------------------------------------------

    fn dispatchPointer(
        self: *Self,
        ev: input.Event,
        mice: []backend.MouseEvent,
        mice_len: *usize,
    ) void {
        switch (ev.event_type) {
            input.POINTER_MOTION => self.dispatchPointerMotion(ev, mice, mice_len),
            input.POINTER_BUTTON_DOWN => self.dispatchPointerButton(ev, true, mice, mice_len),
            input.POINTER_BUTTON_UP => self.dispatchPointerButton(ev, false, mice, mice_len),
            input.POINTER_SCROLL => self.dispatchPointerScroll(ev, mice, mice_len),
            // 5/6 enter/leave: not consumed (see comment in dispatch()).
            else => return, // unknown event_type: skip per spec §Failure modes
        }
    }

    fn dispatchPointerMotion(
        self: *Self,
        ev: input.Event,
        mice: []backend.MouseEvent,
        mice_len: *usize,
    ) void {
        // Payload: x(i32 0-3), y(i32 4-7), dx(i32 8-11), dy(i32 12-15),
        //          buttons(u32 16-19), session_id(u32 20-23)
        const x = std.mem.readInt(i32, ev.payload[0..4], .little);
        const y = std.mem.readInt(i32, ev.payload[4..8], .little);
        const dx = std.mem.readInt(i32, ev.payload[8..12], .little);
        const dy = std.mem.readInt(i32, ev.payload[12..16], .little);

        // Only emit a motion event if there was actual movement. inputfs
        // publishes a motion event with dx=dy=0 immediately before each
        // explicit button_down/button_up to carry the buttons-mask change
        // atomically with the position; the explicit button event that
        // follows on the wire is the authoritative source for the
        // transition. We emit the motion only when there is real
        // movement, and rely on dispatchPointerButton for the press/
        // release. Per shared/INPUT_EVENTS.md, button_down and button_up
        // are first-class event_types; a previous version of this file
        // also synthesised transitions by diffing the buttons mask
        // against last_button_state, which double-counted every click on
        // hardware that sent both events. Removed.
        if (dx != 0 or dy != 0) {
            if (mice_len.* >= mice.len) return;
            mice[mice_len.*] = .{
                .x = x,
                .y = y,
                .button = .left, // unused for motion events per backend.zig
                .event_type = .motion,
                .modifiers = self.last_modifiers,
            };
            mice_len.* += 1;
        }
    }

    fn dispatchPointerButton(
        self: *Self,
        ev: input.Event,
        is_press: bool,
        mice: []backend.MouseEvent,
        mice_len: *usize,
    ) void {
        // Payload: x(i32 0-3), y(i32 4-7), button(u32 8-11),
        //          buttons(u32 12-15), session_id(u32 16-19)
        const x = std.mem.readInt(i32, ev.payload[0..4], .little);
        const y = std.mem.readInt(i32, ev.payload[4..8], .little);
        const button_bit = std.mem.readInt(u32, ev.payload[8..12], .little);

        if (mice_len.* >= mice.len) return;
        const btn = mapButtonBit(button_bit) orelse {
            // Unknown button bit (e.g. side buttons on gaming mice).
            // Phase 1 forwards only left/middle/right; broader support
            // is a Phase 4 cleanup.
            return;
        };
        mice[mice_len.*] = .{
            .x = x,
            .y = y,
            .button = btn,
            .event_type = if (is_press) .press else .release,
            .modifiers = self.last_modifiers,
        };
        mice_len.* += 1;
    }

    fn dispatchPointerScroll(
        self: *Self,
        ev: input.Event,
        mice: []backend.MouseEvent,
        mice_len: *usize,
    ) void {
        // Payload: x(i32 0-3), y(i32 4-7), scroll_dx(i32 8-11),
        //          scroll_dy(i32 12-15), delta_unit(u32 16-19),
        //          session_id(u32 20-23)
        // delta_unit dropped on the floor in Phase 1 (lines vs pixels);
        // backend's MouseEvent has no delta-unit concept.
        const scroll_dx = std.mem.readInt(i32, ev.payload[8..12], .little);
        const scroll_dy = std.mem.readInt(i32, ev.payload[12..16], .little);

        // Match the legacy stashEvtScroll convention: emit press+release
        // pairs of scroll_up/down/left/right MouseButton variants. The
        // MouseEvent schema has no scroll-delta field; magnitude becomes
        // event count if/when a future cut adds it.
        if (scroll_dy != 0) {
            self.pushScrollPair(if (scroll_dy > 0) .scroll_up else .scroll_down, mice, mice_len);
        }
        if (scroll_dx != 0) {
            self.pushScrollPair(if (scroll_dx > 0) .scroll_right else .scroll_left, mice, mice_len);
        }
    }

    fn pushScrollPair(
        self: *Self,
        btn: backend.MouseButton,
        mice: []backend.MouseEvent,
        mice_len: *usize,
    ) void {
        if (mice_len.* + 2 > mice.len) return;
        mice[mice_len.*] = .{
            .x = 0, .y = 0,
            .button = btn,
            .event_type = .press,
            .modifiers = self.last_modifiers,
        };
        mice_len.* += 1;
        mice[mice_len.*] = .{
            .x = 0, .y = 0,
            .button = btn,
            .event_type = .release,
            .modifiers = self.last_modifiers,
        };
        mice_len.* += 1;
    }

};

fn mapButtonBit(bit: u32) ?backend.MouseButton {
    return switch (bit) {
        BUTTON_LEFT => .left,
        BUTTON_RIGHT => .right,
        BUTTON_MIDDLE => .middle,
        else => null,
    };
}

// ============================================================================
// Tests
// ============================================================================

test "mapButtonBit recognises canonical buttons" {
    const testing = std.testing;
    try testing.expectEqual(@as(?backend.MouseButton, .left), mapButtonBit(BUTTON_LEFT));
    try testing.expectEqual(@as(?backend.MouseButton, .right), mapButtonBit(BUTTON_RIGHT));
    try testing.expectEqual(@as(?backend.MouseButton, .middle), mapButtonBit(BUTTON_MIDDLE));
    try testing.expectEqual(@as(?backend.MouseButton, null), mapButtonBit(0x10)); // side button
}

// ============================================================================
// Tests for motion+button-event ordering (regression coverage for the
// pre-fix double-emit bug). The bug: dispatchPointerMotion synthesised
// a press/release transition by diffing the buttons mask against
// last_button_state, AND dispatchPointerButton emitted the same
// transition from the explicit BUTTON_DOWN/BUTTON_UP event that
// followed on the wire. inputfs publishes both in the standard flow,
// so every click was doubled at the client.
//
// Verification on bare metal (pgsd-bare-metal-test-machine) showed
// inputdump emitting one motion + one button_down per click, while
// gesture_inspect saw two press events per click, a direct
// reproduction of the bug. These tests pin the post-fix invariant:
// exactly one MouseEvent of type=press per BUTTON_DOWN, and zero
// MouseEvent emissions from a buttons-mask-only motion event.
// ============================================================================

fn makeMotionEvent(x: i32, y: i32, dx: i32, dy: i32, buttons: u32) input.Event {
    var payload: [32]u8 = .{0} ** 32;
    std.mem.writeInt(i32, payload[0..4], x, .little);
    std.mem.writeInt(i32, payload[4..8], y, .little);
    std.mem.writeInt(i32, payload[8..12], dx, .little);
    std.mem.writeInt(i32, payload[12..16], dy, .little);
    std.mem.writeInt(u32, payload[16..20], buttons, .little);
    return .{
        .seq = 0,
        .ts_ordering = 0,
        .ts_sync = 0,
        .device_slot = 0,
        .source_role = input.SOURCE_POINTER,
        .event_type = input.POINTER_MOTION,
        .flags = 0,
        .payload = payload,
    };
}

fn makeButtonEvent(x: i32, y: i32, button: u32, buttons: u32, is_down: bool) input.Event {
    var payload: [32]u8 = .{0} ** 32;
    std.mem.writeInt(i32, payload[0..4], x, .little);
    std.mem.writeInt(i32, payload[4..8], y, .little);
    std.mem.writeInt(u32, payload[8..12], button, .little);
    std.mem.writeInt(u32, payload[12..16], buttons, .little);
    return .{
        .seq = 0,
        .ts_ordering = 0,
        .ts_sync = 0,
        .device_slot = 0,
        .source_role = input.SOURCE_POINTER,
        .event_type = if (is_down) input.POINTER_BUTTON_DOWN else input.POINTER_BUTTON_UP,
        .flags = 0,
        .payload = payload,
    };
}

fn makeInert() InputfsInput {
    // Construct an InputfsInput without going through init() so tests
    // don't need the kernel ring. The dispatch functions touch only
    // self.last_modifiers; reader is held but unused. notify_fd is
    // left null because tests do not exercise the notify-cdev path
    // (added in AD-41.3); the field is purely for the daemon's
    // poll-set plumbing and has no effect on dispatch behaviour.
    return .{
        .reader = .{ .map = null, .fd = -1, .last_consumed = 0 },
        .last_modifiers = 0,
        .notify_fd = null,
        .wake_kq = null,
    };
}

test "motion with dx=dy=0 and a buttons-mask change emits no events" {
    // Pre-fix behaviour: dispatchPointerMotion would synthesise a press
    // because (buttons=0x1) ^ (last_button_state=0) != 0. Post-fix:
    // the synthesis is gone and motion with no movement emits nothing.
    // The explicit BUTTON_DOWN that follows on the wire is the only
    // place a press is emitted.
    const testing = std.testing;
    var ifi = makeInert();
    var mice: [4]backend.MouseEvent = undefined;
    var mice_len: usize = 0;

    // Kernel-typical pre-button motion: dx=dy=0, buttons=0x1.
    const motion_with_press = makeMotionEvent(100, 200, 0, 0, 0x1);
    ifi.dispatchPointerMotion(motion_with_press, &mice, &mice_len);

    try testing.expectEqual(@as(usize, 0), mice_len);
}

test "explicit BUTTON_DOWN emits exactly one press event" {
    const testing = std.testing;
    var ifi = makeInert();
    var mice: [4]backend.MouseEvent = undefined;
    var mice_len: usize = 0;

    const ev = makeButtonEvent(100, 200, BUTTON_LEFT, 0x1, true);
    ifi.dispatchPointerButton(ev, true, &mice, &mice_len);

    try testing.expectEqual(@as(usize, 1), mice_len);
    try testing.expectEqual(backend.MouseEventType.press, mice[0].event_type);
    try testing.expectEqual(backend.MouseButton.left, mice[0].button);
    try testing.expectEqual(@as(i32, 100), mice[0].x);
    try testing.expectEqual(@as(i32, 200), mice[0].y);
}

test "kernel click sequence (motion + button_down + motion + button_up) emits exactly press+release" {
    // The kernel pattern observed on bare metal: each click is FOUR
    // events on the inputfs ring: motion(dx=0 dy=0 buttons=0x1),
    // button_down, motion(dx=0 dy=0 buttons=0x0), button_up. The
    // pre-fix code emitted four MouseEvents per click (one synthesis
    // from each motion plus one from each explicit button event).
    // Post-fix: exactly two MouseEvents (one press, one release).
    const testing = std.testing;
    var ifi = makeInert();
    var mice: [8]backend.MouseEvent = undefined;
    var mice_len: usize = 0;

    const m1 = makeMotionEvent(100, 200, 0, 0, 0x1); // pre-press motion
    const bd = makeButtonEvent(100, 200, BUTTON_LEFT, 0x1, true);
    const m2 = makeMotionEvent(100, 200, 0, 0, 0x0); // pre-release motion
    const bu = makeButtonEvent(100, 200, BUTTON_LEFT, 0x0, false);

    ifi.dispatchPointerMotion(m1, &mice, &mice_len);
    ifi.dispatchPointerButton(bd, true, &mice, &mice_len);
    ifi.dispatchPointerMotion(m2, &mice, &mice_len);
    ifi.dispatchPointerButton(bu, false, &mice, &mice_len);

    try testing.expectEqual(@as(usize, 2), mice_len);
    try testing.expectEqual(backend.MouseEventType.press, mice[0].event_type);
    try testing.expectEqual(backend.MouseButton.left, mice[0].button);
    try testing.expectEqual(backend.MouseEventType.release, mice[1].event_type);
    try testing.expectEqual(backend.MouseButton.left, mice[1].button);
}

test "real motion (dx or dy nonzero) emits one motion event" {
    const testing = std.testing;
    var ifi = makeInert();
    var mice: [4]backend.MouseEvent = undefined;
    var mice_len: usize = 0;

    const ev = makeMotionEvent(150, 250, 5, -3, 0x0);
    ifi.dispatchPointerMotion(ev, &mice, &mice_len);

    try testing.expectEqual(@as(usize, 1), mice_len);
    try testing.expectEqual(backend.MouseEventType.motion, mice[0].event_type);
    try testing.expectEqual(@as(i32, 150), mice[0].x);
    try testing.expectEqual(@as(i32, 250), mice[0].y);
}

// ============================================================================
// Migration raw-fd idiom (P2 WT2b): file-local close helper.
// Replaces posix.close, removed in Zig 0.16, with the raw libc call. Mirrors
// the closeFd precedent in socket_server. Duplicated per file by design.
// ============================================================================

fn closeFd(fd: std.posix.fd_t) void {
    _ = std.posix.system.close(fd);
}
