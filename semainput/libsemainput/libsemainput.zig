//! libsemainput — userland gesture recognition library.
//!
//! Recognises gestures (n-click, drag, two-finger scroll, pinch,
//! three-finger swipe, tap) from typed pointer and touch events.
//! Pure compute: no IO, no global state, no allocation outside
//! the supplied allocator.
//!
//! Per `inputfs/docs/adr/0016-libsemainput-extraction.md`:
//!
//!   - Library does no IO. Accepts typed events; returns typed
//!     events. The compositor (semadrawd) is the sole reader of
//!     the inputfs event ring; it feeds this recogniser and
//!     routes the recogniser's output to clients.
//!   - `LibsemainputInput` mirrors inputfs's wire format. Carries
//!     `device_slot: u16` so the recogniser can key per-device
//!     state without an Aggregator.
//!   - `LibsemainputOutput` is the gesture vocabulary. Caller
//!     decides what to do with each output (semadrawd routes to
//!     focused client; a client app reacts directly).
//!   - `GestureRecognizer` is per-instance. Recommended
//!     cardinality is one per session in semadrawd; the library
//!     is agnostic.
//!
//! API:
//!
//!     var rec = libsemainput.GestureRecognizer.init(allocator);
//!     defer rec.deinit();
//!
//!     while (events.next()) |raw_event| {
//!         const input = translateToLibsemainputInput(raw_event);
//!         try rec.handleEvent(input);
//!         while (rec.nextOutput()) |out| {
//!             // dispatch out
//!         }
//!     }
//!
//! `handleEvent` enqueues zero or more outputs into an internal
//! FIFO. `nextOutput` drains them. A single input may produce
//! multiple outputs (e.g. `pinch_begin` + `intent_hint` from one
//! touch_move that activates a pinch); the caller drains the
//! queue after each input.
//!
//! Migrated from `semainput/src/gesture.zig` (1,044 lines) during
//! AD-2a Phase 2.3. Algorithms and thresholds match the daemon
//! version exactly; the library form differs only in:
//!   - Input shape: typed `LibsemainputInput` not `semantic.SemanticEvent`.
//!   - Output shape: queued typed `LibsemainputOutput` not
//!     stdout JSON-line writes.
//!   - Per-device key: `device_slot: u16` not `device_name: []const u8`.
//!   - No globals: no session token, no audio clock reader, no
//!     sequence counter. Audio timestamps arrive via the input
//!     events' optional `ts_audio_samples` field.

const std = @import("std");

// ============================================================================
// Public types
// ============================================================================

/// Events the recogniser accepts. The shape mirrors the inputfs
/// wire format (per `shared/INPUT_EVENTS.md`) with three
/// adjustments:
///
///   - `session_id` is omitted. The library does not route events;
///     callers either route before calling (semadrawd) or are the
///     intended recipient (clients).
///   - `delta_unit` is omitted from scroll. The recogniser treats
///     both lines and pixels the same way (it triggers on any
///     non-trivial delta); semantic interpretation is the caller's
///     concern.
///   - `device_slot` is preserved (the inputfs ring's u16 device
///     index). The recogniser keys per-device state on this slot.
///
/// Timestamps: every variant carries `ts_ns` (monotonic
/// nanoseconds) and an optional `ts_audio_samples`. The audio
/// timestamp, when available, is preferred for cadence-sensitive
/// recognition (n-click in particular: audio sample counts are
/// immune to OS scheduling jitter that wall-clock nanoseconds
/// inherit). Callers without an audio clock pass null; the
/// recogniser falls back to `ts_ns`.
pub const LibsemainputInput = union(enum) {
    pointer_motion: PointerMotion,
    pointer_button: PointerButton,
    pointer_scroll: PointerScroll,
    touch_down: Touch,
    touch_move: Touch,
    touch_up: TouchUp,

    pub const PointerMotion = struct {
        device_slot: u16,
        x: i32,
        y: i32,
        dx: i32,
        dy: i32,
        buttons: u32,
        ts_ns: u64,
        ts_audio_samples: ?u64 = null,
    };

    pub const PointerButton = struct {
        device_slot: u16,
        x: i32,
        y: i32,
        button: u32,
        pressed: bool,
        ts_ns: u64,
        ts_audio_samples: ?u64 = null,
    };

    pub const PointerScroll = struct {
        device_slot: u16,
        dx: i32,
        dy: i32,
        ts_ns: u64,
        ts_audio_samples: ?u64 = null,
    };

    pub const Touch = struct {
        device_slot: u16,
        contact_id: u32,
        x: i32,
        y: i32,
        ts_ns: u64,
        ts_audio_samples: ?u64 = null,
    };

    pub const TouchUp = struct {
        device_slot: u16,
        contact_id: u32,
        ts_ns: u64,
        ts_audio_samples: ?u64 = null,
    };
};

/// Gesture events the recogniser produces. See ADR 0016 for
/// the bracketing convention and intent_hint semantics.
pub const LibsemainputOutput = union(enum) {
    // Discrete and drag gestures.
    n_click: NClick,
    drag_start: DragPoint,
    drag_move: DragPoint,
    drag_end: DragPoint,
    tap: TapPoint,

    // Two-finger scroll.
    scroll_begin: EndMarker,
    two_finger_scroll: TwoFingerScroll,
    scroll_end: EndMarker,

    // Pinch.
    pinch_begin: Pinch,
    pinch: PinchUpdate,
    pinch_end: EndMarker,

    // Three-finger swipe.
    three_finger_swipe_begin: ThreeFingerSwipe,
    three_finger_swipe: ThreeFingerSwipe,
    three_finger_swipe_end: EndMarker,

    // Early prediction signal.
    intent_hint: IntentHint,

    /// Recogniser-internal field carried on every output variant.
    /// The daemon copies it into the GestureEventMsg.finger_count
    /// header field at wire-emit time. ADR 0017-rev2 addendum
    /// (2026-05-04) confirms finger_count is the one piece of
    /// gesture-intrinsic state worth exposing on output; everything
    /// else (timestamps, modifiers) lives at the input or daemon
    /// layer.
    ///
    /// Convention:
    ///   - Touch gestures: count of active contacts on the
    ///     originating device at emit time.
    ///   - Pointer gestures (n_click, drag_*, tap): 1.
    ///   - End/cancel variants: count at emit time, which may be 0
    ///     after the last finger lifts. Clients reasoning about
    ///     "this was an N-finger gesture" should remember the
    ///     count from the begin event rather than the end event.
    ///     This matches the event-stream wire model: each event is
    ///     self-sufficient at the moment it occurs; gesture-as-
    ///     object reconstruction is the client's responsibility.
    pub const NClick = struct {
        button: u32,
        count: u32,
        x: i32,
        y: i32,
        finger_count: u8,
    };

    pub const DragPoint = struct {
        contact_id: u32,
        x: i32,
        y: i32,
        finger_count: u8,
    };

    pub const TwoFingerScroll = struct {
        dx: i32,
        dy: i32,
        finger_count: u8,
    };

    pub const Pinch = struct {
        delta: i32,
        scale_factor: f32,
        finger_count: u8,
    };

    pub const PinchUpdate = struct {
        delta: i32,
        scale_factor: f32,
        direction: PinchDirection,
        finger_count: u8,
    };

    pub const ThreeFingerSwipe = struct {
        dx: i32,
        dy: i32,
        total_dx: i32,
        total_dy: i32,
        axis_locked: AxisLock,
        confidence: u8,
        finger_count: u8,
    };

    pub const TapPoint = struct {
        contact_id: u32,
        x: i32,
        y: i32,
        finger_count: u8,
    };

    /// Marker payload for end-of-gesture variants (scroll_end,
    /// pinch_end, three_finger_swipe_end, scroll_begin). Wire-format-
    /// wise these gestures carry no payload bytes after the
    /// GestureEventMsg header (per the protocol.zig payloadSize
    /// table); EndMarker exists solely to give the recogniser's
    /// output a place to put finger_count without making it a
    /// special case.
    pub const EndMarker = struct {
        finger_count: u8,
    };

    /// Early prediction hint for an in-progress gesture.
    /// `axis` semantics depend on `gesture`:
    ///   - two_finger_scroll, three_finger_swipe: horizontal | vertical
    ///   - pinch: in | out (delta direction)
    ///   - none is a defensive fallback; callers may ignore.
    pub const IntentHint = struct {
        gesture: Kind,
        axis: Axis,
        confidence: u8,
        finger_count: u8,
    };

    pub const PinchDirection = enum { in, out };
    pub const AxisLock = enum { none, horizontal, vertical };
    pub const Axis = enum { none, horizontal, vertical, in, out };
    pub const Kind = enum { two_finger_scroll, pinch, three_finger_swipe };
};

// ============================================================================
// Tunables — match `semainput/src/gesture.zig` exactly.
// ============================================================================

const TapMaxDurationNs: u64 = 250 * std.time.ns_per_ms;
const DragThreshold: i32 = 24;
const ScrollActivateThreshold: i32 = 2;
const ScrollReleaseThreshold: i32 = 1;
const ScrollEmitThreshold: i32 = 1;
const ScrollAxisDominanceMargin: i32 = 1;
const ScrollReleaseFrames: u32 = 3;
const PostScrollCooldownFrames: u32 = 4;
const PinchActivateThreshold: i32 = 8;
const PinchEmitThreshold: i32 = 2;
const PinchJitterDeadzone: i32 = 4;
const ThreeFingerSwipeActivateThreshold: i32 = 18;
const ThreeFingerSwipeEmitThreshold: i32 = 2;
const ThreeFingerArbitrationCooldownFrames: u32 = 4;
const ThreeFingerAxisLockMargin: i32 = 3;
const ThreeFingerAxisEarlyMargin: i32 = 2;
const VelocityScaleNumerator: i32 = 1;
const VelocityScaleDenominator: i32 = 2;
const MaxDeltaStep: i32 = 3;

// N-click recogniser thresholds. See `semainput/docs/NClickDesign.md`.
//
// NClickIntervalSamples — maximum audio-sample delta between
// successive clicks for them to be considered the same N-click
// sequence. 24000 is 500 ms at 48 kHz. When the audio clock is
// unavailable, the recogniser falls back to wall clock and uses
// NClickIntervalNs as the equivalent.
//
// NClickRadiusUnits — maximum device-unit distance between
// successive click positions. The unit is raw pointer units; for
// typical mouse hardware, 8 units approximates 8 pixels of motion.
const NClickIntervalSamples: u64 = 24_000;
const NClickIntervalNs: u64 = 500 * std.time.ns_per_ms;
const NClickRadiusUnits: i32 = 8;

// ============================================================================
// Internal state
// ============================================================================

const ContactState = struct {
    device_slot: u16,
    contact_id: u32,
    is_active: bool,
    start_x: i32,
    start_y: i32,
    prev_x: i32,
    prev_y: i32,
    last_x: i32,
    last_y: i32,
    down_ns: u64,
    drag_started: bool,
};

const DeviceGestureState = struct {
    device_slot: u16,
    last_scroll_dx: i32,
    last_scroll_dy: i32,
    multitouch_scroll_active: bool,
    scroll_locked: bool,
    release_counter: u32,
    post_scroll_cooldown_frames: u32,
    pinch_locked: bool,
    last_pinch_delta: i32,
    swipe3_locked: bool,
    swipe3_arbitrating: bool,
    swipe3_guard_frames: u32,
    swipe3_axis_lock: LibsemainputOutput.AxisLock,
    swipe3_axis_candidate: LibsemainputOutput.AxisLock,
    swipe3_start_cx: i32,
    swipe3_start_cy: i32,
    swipe3_have_anchor: bool,
    last_swipe3_dx: i32,
    last_swipe3_dy: i32,
};

/// Per-device record of the most recent completed click, used by
/// the N-click recogniser to determine whether a new click extends
/// an existing sequence or starts a fresh one.
const ClickHistory = struct {
    device_slot: u16,
    button: u32,
    x: i32,
    y: i32,
    /// Audio-sample timestamp of the previous up-event in this
    /// sequence. When the audio clock is unavailable, this is 0
    /// and ts_wall_ns is used instead.
    ts_audio_samples: u64,
    /// Wall-clock timestamp of the previous up-event in this
    /// sequence. Always valid; used as the timing reference when
    /// audio is unavailable.
    ts_wall_ns: u64,
    /// Position of the most recent down-event in the in-progress
    /// click. Compared against the up-event position to enforce
    /// click-vs-drag.
    down_x: i32,
    down_y: i32,
    /// Number of clicks in the current sequence (1 = single click,
    /// 2 = double, ...).
    count: u32,
};

// ============================================================================
// GestureRecognizer
// ============================================================================

/// Per-caller gesture recognition state. Instances are independent;
/// multiple recognisers may run in the same process (e.g.
/// semadrawd holds one per session) without interfering. The
/// recogniser owns its allocator-borrowed state and frees it on
/// `deinit`.
pub const GestureRecognizer = struct {
    allocator: std.mem.Allocator,
    contacts: std.ArrayList(ContactState),
    device_states: std.ArrayList(DeviceGestureState),
    click_history: std.ArrayList(ClickHistory),
    /// FIFO of gesture events the recogniser has produced but the
    /// caller has not yet consumed. handleEvent appends; nextOutput
    /// pops from the front.
    pending: std.ArrayList(LibsemainputOutput),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .contacts = .{},
            .device_states = .{},
            .click_history = .{},
            .pending = .{},
        };
    }

    pub fn deinit(self: *Self) void {
        // No string-dup'd fields after the migration; all per-device
        // keys are u16 device_slot. Plain list deinits.
        self.contacts.deinit(self.allocator);
        self.device_states.deinit(self.allocator);
        self.click_history.deinit(self.allocator);
        self.pending.deinit(self.allocator);
    }

    /// Feed one input event. Recognition state advances; any
    /// produced gesture events are appended to the internal FIFO.
    /// Caller drains via `nextOutput`.
    pub fn handleEvent(self: *Self, input: LibsemainputInput) !void {
        switch (input) {
            .pointer_button => |e| try self.handlePointerButton(e),
            .touch_down => |e| try self.handleTouchDown(e),
            .touch_move => |e| try self.handleTouchMove(e),
            .touch_up => |e| try self.handleTouchUp(e),
            // pointer_motion and pointer_scroll do not feed the
            // current gesture vocabulary (motion is handled by the
            // compositor's cursor logic; scroll is a passthrough).
            // No-op here; the cases exist for completeness and to
            // make adding future gestures (e.g. high-velocity
            // pointer-fling) a one-line change.
            .pointer_motion, .pointer_scroll => {},
        }
    }

    /// Pop and return the next queued gesture event, or null if
    /// the queue is empty. Caller invokes in a loop after each
    /// `handleEvent`.
    pub fn nextOutput(self: *Self) ?LibsemainputOutput {
        if (self.pending.items.len == 0) return null;
        return self.pending.orderedRemove(0);
    }

    fn enqueue(self: *Self, out: LibsemainputOutput) !void {
        try self.pending.append(self.allocator, out);
    }

    // ========================================================================
    // Per-device state lookup
    // ========================================================================

    fn findContact(self: *Self, device_slot: u16, contact_id: u32) ?*ContactState {
        for (self.contacts.items) |*c| {
            if (c.contact_id == contact_id and c.device_slot == device_slot) return c;
        }
        return null;
    }

    fn getOrCreateContact(self: *Self, device_slot: u16, contact_id: u32) !*ContactState {
        if (self.findContact(device_slot, contact_id)) |c| return c;
        try self.contacts.append(self.allocator, .{
            .device_slot = device_slot,
            .contact_id = contact_id,
            .is_active = false,
            .start_x = 0,
            .start_y = 0,
            .prev_x = 0,
            .prev_y = 0,
            .last_x = 0,
            .last_y = 0,
            .down_ns = 0,
            .drag_started = false,
        });
        return &self.contacts.items[self.contacts.items.len - 1];
    }

    fn findDeviceState(self: *Self, device_slot: u16) ?*DeviceGestureState {
        for (self.device_states.items) |*s| {
            if (s.device_slot == device_slot) return s;
        }
        return null;
    }

    fn getOrCreateDeviceState(self: *Self, device_slot: u16) !*DeviceGestureState {
        if (self.findDeviceState(device_slot)) |s| return s;
        try self.device_states.append(self.allocator, .{
            .device_slot = device_slot,
            .last_scroll_dx = 0,
            .last_scroll_dy = 0,
            .multitouch_scroll_active = false,
            .scroll_locked = false,
            .release_counter = 0,
            .post_scroll_cooldown_frames = 0,
            .pinch_locked = false,
            .last_pinch_delta = 0,
            .swipe3_locked = false,
            .swipe3_arbitrating = false,
            .swipe3_guard_frames = 0,
            .swipe3_axis_lock = .none,
            .swipe3_axis_candidate = .none,
            .swipe3_start_cx = 0,
            .swipe3_start_cy = 0,
            .swipe3_have_anchor = false,
            .last_swipe3_dx = 0,
            .last_swipe3_dy = 0,
        });
        return &self.device_states.items[self.device_states.items.len - 1];
    }

    // ========================================================================
    // Math + axis helpers (pure functions; identical to gesture.zig)
    // ========================================================================

    fn absDiff(a: i32, b: i32) i32 {
        return if (a >= b) a - b else b - a;
    }

    fn sign(v: i32) i32 {
        return if (v > 0) 1 else if (v < 0) -1 else 0;
    }

    fn clampDeltaStep(prev: i32, next: i32) i32 {
        const diff = next - prev;
        if (diff > MaxDeltaStep) return prev + MaxDeltaStep;
        if (diff < -MaxDeltaStep) return prev - MaxDeltaStep;
        return next;
    }

    fn normalizeVelocity(v: i32) i32 {
        return @divTrunc(v * VelocityScaleNumerator, VelocityScaleDenominator);
    }

    fn accelerateVelocity(v: i32) i32 {
        const av = absDiff(v, 0);
        if (av <= 2) return v;
        if (av <= 8) return v + sign(v);
        if (av <= 16) return v + (2 * sign(v));
        return v + (3 * sign(v));
    }

    fn applyAxisLock(lock: LibsemainputOutput.AxisLock, dx: i32, dy: i32) struct { dx: i32, dy: i32 } {
        return switch (lock) {
            .horizontal => .{ .dx = dx, .dy = 0 },
            .vertical => .{ .dx = 0, .dy = dy },
            .none => .{ .dx = dx, .dy = dy },
        };
    }

    fn chooseAxisLock(dx: i32, dy: i32) LibsemainputOutput.AxisLock {
        const ax = absDiff(dx, 0);
        const ay = absDiff(dy, 0);
        if (ax >= ay + ThreeFingerAxisLockMargin) return .horizontal;
        if (ay >= ax + ThreeFingerAxisLockMargin) return .vertical;
        return .none;
    }

    fn chooseAxisCandidate(dx: i32, dy: i32) LibsemainputOutput.AxisLock {
        const ax = absDiff(dx, 0);
        const ay = absDiff(dy, 0);
        if (ax >= ay + ThreeFingerAxisEarlyMargin) return .horizontal;
        if (ay >= ax + ThreeFingerAxisEarlyMargin) return .vertical;
        return .none;
    }

    fn computeConfidence(dx: i32, dy: i32, axis: LibsemainputOutput.AxisLock) u8 {
        const ax = absDiff(dx, 0);
        const ay = absDiff(dy, 0);
        const dominant = switch (axis) {
            .horizontal => ax,
            .vertical => ay,
            .none => @max(ax, ay),
        };
        const secondary = switch (axis) {
            .horizontal => ay,
            .vertical => ax,
            .none => @min(ax, ay),
        };
        const diff = dominant - secondary;
        var score: i32 = 50 + diff * 5;
        if (dominant >= 12) score += 15;
        if (dominant >= 20) score += 10;
        if (score < 0) score = 0;
        if (score > 100) score = 100;
        return @intCast(score);
    }

    fn axisLockToAxis(lock: LibsemainputOutput.AxisLock) LibsemainputOutput.Axis {
        return switch (lock) {
            .none => .none,
            .horizontal => .horizontal,
            .vertical => .vertical,
        };
    }

    fn distSquared(ax: i32, ay: i32, bx: i32, by: i32) i64 {
        const dx: i64 = @as(i64, ax) - @as(i64, bx);
        const dy: i64 = @as(i64, ay) - @as(i64, by);
        return dx * dx + dy * dy;
    }

    // ========================================================================
    // Per-device aggregate queries (over active contacts)
    // ========================================================================

    fn activeContactsForDevice(self: *Self, device_slot: u16) usize {
        var count: usize = 0;
        for (self.contacts.items) |c| {
            if (c.is_active and c.device_slot == device_slot) count += 1;
        }
        return count;
    }

    /// Active contact count for the given device, clamped to u8.
    /// Used to populate the finger_count field on touch-gesture
    /// outputs (per ADR 0017-rev2 addendum 2026-05-04). Pointer-
    /// driven gestures (n_click, drag_*, tap from a click) bypass
    /// this and emit finger_count = 1 directly.
    fn fingerCountForDevice(self: *Self, device_slot: u16) u8 {
        const count = self.activeContactsForDevice(device_slot);
        return @intCast(@min(count, @as(usize, 255)));
    }

    fn averageVelocityXForDevice(self: *Self, device_slot: u16) i32 {
        var total: i32 = 0;
        var count: i32 = 0;
        for (self.contacts.items) |c| {
            if (c.is_active and c.device_slot == device_slot) {
                total += c.last_x - c.prev_x;
                count += 1;
            }
        }
        return if (count > 0) normalizeVelocity(@divTrunc(total, count)) else 0;
    }

    fn averageVelocityYForDevice(self: *Self, device_slot: u16) i32 {
        var total: i32 = 0;
        var count: i32 = 0;
        for (self.contacts.items) |c| {
            if (c.is_active and c.device_slot == device_slot) {
                total += c.last_y - c.prev_y;
                count += 1;
            }
        }
        return if (count > 0) normalizeVelocity(@divTrunc(total, count)) else 0;
    }

    fn averagePositionXForDevice(self: *Self, device_slot: u16) i32 {
        var total: i32 = 0;
        var count: i32 = 0;
        for (self.contacts.items) |c| {
            if (c.is_active and c.device_slot == device_slot) {
                total += c.last_x;
                count += 1;
            }
        }
        return if (count > 0) @divTrunc(total, count) else 0;
    }

    fn averagePositionYForDevice(self: *Self, device_slot: u16) i32 {
        var total: i32 = 0;
        var count: i32 = 0;
        for (self.contacts.items) |c| {
            if (c.is_active and c.device_slot == device_slot) {
                total += c.last_y;
                count += 1;
            }
        }
        return if (count > 0) @divTrunc(total, count) else 0;
    }

    fn averagePrevPositionXForDevice(self: *Self, device_slot: u16) i32 {
        var total: i32 = 0;
        var count: i32 = 0;
        for (self.contacts.items) |c| {
            if (c.is_active and c.device_slot == device_slot) {
                total += c.prev_x;
                count += 1;
            }
        }
        return if (count > 0) @divTrunc(total, count) else 0;
    }

    fn averagePrevPositionYForDevice(self: *Self, device_slot: u16) i32 {
        var total: i32 = 0;
        var count: i32 = 0;
        for (self.contacts.items) |c| {
            if (c.is_active and c.device_slot == device_slot) {
                total += c.prev_y;
                count += 1;
            }
        }
        return if (count > 0) @divTrunc(total, count) else 0;
    }

    fn contactsSupportScroll(self: *Self, device_slot: u16) bool {
        var found: usize = 0;
        var first_dx: i32 = 0;
        var first_dy: i32 = 0;
        for (self.contacts.items) |c| {
            if (!(c.is_active and c.device_slot == device_slot)) continue;
            const dx = c.last_x - c.prev_x;
            const dy = c.last_y - c.prev_y;
            if (found == 0) {
                first_dx = dx;
                first_dy = dy;
                found = 1;
                continue;
            }
            const x_ok = sign(dx) == 0 or sign(first_dx) == 0 or sign(dx) == sign(first_dx);
            const y_ok = sign(dy) == 0 or sign(first_dy) == 0 or sign(dy) == sign(first_dy);
            if (!(x_ok and y_ok)) return false;
            found += 1;
        }
        return found >= 2;
    }

    fn axisDominant(avg_dx: i32, avg_dy: i32) bool {
        const ax = absDiff(avg_dx, 0);
        const ay = absDiff(avg_dy, 0);
        return ax >= ay + ScrollAxisDominanceMargin or ay >= ax + ScrollAxisDominanceMargin;
    }

    fn smoothScroll(self: *Self, device_slot: u16, dx: i32, dy: i32) !struct { dx: i32, dy: i32 } {
        const state = try self.getOrCreateDeviceState(device_slot);
        const raw_dx = @divTrunc(dx + state.last_scroll_dx, 2);
        const raw_dy = @divTrunc(dy + state.last_scroll_dy, 2);
        const smoothed_dx = clampDeltaStep(state.last_scroll_dx, raw_dx);
        const smoothed_dy = clampDeltaStep(state.last_scroll_dy, raw_dy);
        state.last_scroll_dx = smoothed_dx;
        state.last_scroll_dy = smoothed_dy;
        return .{ .dx = smoothed_dx, .dy = smoothed_dy };
    }

    fn smoothSwipe3(self: *Self, device_slot: u16, dx: i32, dy: i32) !struct { dx: i32, dy: i32 } {
        const state = try self.getOrCreateDeviceState(device_slot);
        const raw_dx = @divTrunc(dx + state.last_swipe3_dx, 2);
        const raw_dy = @divTrunc(dy + state.last_swipe3_dy, 2);
        const smoothed_dx = clampDeltaStep(state.last_swipe3_dx, raw_dx);
        const smoothed_dy = clampDeltaStep(state.last_swipe3_dy, raw_dy);
        state.last_swipe3_dx = smoothed_dx;
        state.last_swipe3_dy = smoothed_dy;
        return .{ .dx = smoothed_dx, .dy = smoothed_dy };
    }

    fn getFirstNActiveContacts(self: *Self, device_slot: u16, n: usize, out: []ContactState) usize {
        var count: usize = 0;
        for (self.contacts.items) |c| {
            if (count >= n) break;
            if (c.is_active and c.device_slot == device_slot) {
                out[count] = c;
                count += 1;
            }
        }
        return count;
    }

    fn pinchDistanceSquared(a: ContactState, b: ContactState) i64 {
        const dx: i64 = @as(i64, a.last_x) - @as(i64, b.last_x);
        const dy: i64 = @as(i64, a.last_y) - @as(i64, b.last_y);
        return dx * dx + dy * dy;
    }

    fn pinchPrevDistanceSquared(a: ContactState, b: ContactState) i64 {
        const dx: i64 = @as(i64, a.prev_x) - @as(i64, b.prev_x);
        const dy: i64 = @as(i64, a.prev_y) - @as(i64, b.prev_y);
        return dx * dx + dy * dy;
    }

    // ========================================================================
    // Frame-tick helpers
    // ========================================================================

    fn tickCooldown(state: *DeviceGestureState) void {
        if (state.post_scroll_cooldown_frames > 0) state.post_scroll_cooldown_frames -= 1;
    }

    fn tickSwipe3Guard(state: *DeviceGestureState) void {
        if (state.swipe3_guard_frames > 0) state.swipe3_guard_frames -= 1;
        if (state.swipe3_guard_frames == 0 and !state.swipe3_locked) {
            state.swipe3_arbitrating = false;
            state.swipe3_have_anchor = false;
        }
    }

    fn endScrollWithCooldown(self: *Self, state: *DeviceGestureState) !void {
        state.multitouch_scroll_active = false;
        state.scroll_locked = false;
        state.release_counter = 0;
        state.post_scroll_cooldown_frames = PostScrollCooldownFrames;
        try self.enqueue(.{ .scroll_end = .{ .finger_count = self.fingerCountForDevice(state.device_slot) } });
    }

    fn clearHighLevelLocks(state: *DeviceGestureState) void {
        state.multitouch_scroll_active = false;
        state.scroll_locked = false;
        state.release_counter = 0;
        state.pinch_locked = false;
        state.last_pinch_delta = 0;
        state.swipe3_locked = false;
        state.swipe3_arbitrating = false;
        state.swipe3_guard_frames = 0;
        state.swipe3_axis_lock = .none;
        state.swipe3_axis_candidate = .none;
        state.swipe3_start_cx = 0;
        state.swipe3_start_cy = 0;
        state.swipe3_have_anchor = false;
        state.last_swipe3_dx = 0;
        state.last_swipe3_dy = 0;
    }

    fn endPinch(self: *Self, state: *DeviceGestureState) !void {
        if (state.pinch_locked) {
            state.pinch_locked = false;
            state.last_pinch_delta = 0;
            try self.enqueue(.{ .pinch_end = .{ .finger_count = self.fingerCountForDevice(state.device_slot) } });
        }
    }

    fn endSwipe3(self: *Self, state: *DeviceGestureState) !void {
        if (state.swipe3_locked) {
            state.swipe3_locked = false;
            state.last_swipe3_dx = 0;
            state.last_swipe3_dy = 0;
            state.swipe3_axis_lock = .none;
            try self.enqueue(.{ .three_finger_swipe_end = .{ .finger_count = self.fingerCountForDevice(state.device_slot) } });
        }
        state.swipe3_arbitrating = false;
        state.swipe3_guard_frames = 0;
        state.swipe3_axis_candidate = .none;
        state.swipe3_start_cx = 0;
        state.swipe3_start_cy = 0;
        state.swipe3_have_anchor = false;
        if (!state.swipe3_locked) state.swipe3_axis_lock = .none;
    }

    fn startSwipe3Arbitration(self: *Self, state: *DeviceGestureState, device_slot: u16) void {
        state.swipe3_arbitrating = true;
        state.swipe3_guard_frames = ThreeFingerArbitrationCooldownFrames;
        state.swipe3_axis_lock = .none;
        state.swipe3_axis_candidate = .none;
        state.swipe3_start_cx = self.averagePositionXForDevice(device_slot);
        state.swipe3_start_cy = self.averagePositionYForDevice(device_slot);
        state.swipe3_have_anchor = true;
        state.pinch_locked = false;
        state.last_pinch_delta = 0;
        state.multitouch_scroll_active = false;
        state.scroll_locked = false;
        state.release_counter = 0;
    }

    fn enforceStrictArbitration(self: *Self, device_slot: u16) !void {
        const state = try self.getOrCreateDeviceState(device_slot);
        const active = self.activeContactsForDevice(device_slot);

        if (active >= 3) {
            try self.endPinch(state);
            state.multitouch_scroll_active = false;
            state.scroll_locked = false;
            state.release_counter = 0;
            if (!state.swipe3_locked and !state.swipe3_arbitrating) {
                self.startSwipe3Arbitration(state, device_slot);
            }
        }

        if (active != 2) {
            try self.endPinch(state);
        }

        if (active != 3) {
            try self.endSwipe3(state);
        }

        if (active == 0) {
            Self.clearHighLevelLocks(state);
        }
    }

    // ========================================================================
    // Multi-touch state machines (pinch, three-finger swipe, two-finger scroll)
    // ========================================================================

    fn updatePinchState(self: *Self, device_slot: u16) !void {
        const state = try self.getOrCreateDeviceState(device_slot);
        const active = self.activeContactsForDevice(device_slot);

        if (state.scroll_locked or state.multitouch_scroll_active or state.swipe3_locked or state.swipe3_arbitrating) {
            try self.endPinch(state);
            return;
        }

        if (active != 2) {
            try self.endPinch(state);
            return;
        }

        var contacts: [2]ContactState = undefined;
        if (self.getFirstNActiveContacts(device_slot, 2, &contacts) != 2) return;

        const cur = pinchDistanceSquared(contacts[0], contacts[1]);
        const prev = pinchPrevDistanceSquared(contacts[0], contacts[1]);

        // Calibrated pixel-distance delta: difference of Euclidean distances.
        const cur_dist: f64 = @sqrt(@as(f64, @floatFromInt(cur)));
        const prev_dist: f64 = @sqrt(@as(f64, @floatFromInt(prev)));
        const delta: i32 = @intFromFloat(cur_dist - prev_dist);

        // scale_factor: ratio of current to previous finger separation.
        // 1.0 = no change, >1.0 = spreading (zoom in), <1.0 = pinching (zoom out).
        // Clamped to [0.01, 99.99] to guarantee finite, positive output.
        const scale_factor_f64: f64 = if (prev_dist > 0.0)
            std.math.clamp(cur_dist / prev_dist, 0.01, 99.99)
        else
            1.0;
        const scale_factor: f32 = @floatCast(scale_factor_f64);

        if (!state.pinch_locked) {
            if (absDiff(delta, 0) >= PinchActivateThreshold) {
                state.pinch_locked = true;
                state.last_pinch_delta = delta;
                try self.enqueue(.{ .pinch_begin = .{
                    .delta = delta,
                    .scale_factor = scale_factor,
                    .finger_count = self.fingerCountForDevice(device_slot),
                } });
                const confidence_raw: i32 = 60 + absDiff(delta, 0);
                const confidence: u8 = @intCast(@min(@as(i32, 100), confidence_raw));
                try self.enqueue(.{ .intent_hint = .{
                    .gesture = .pinch,
                    .axis = if (delta > 0) .out else .in,
                    .confidence = confidence,
                    .finger_count = self.fingerCountForDevice(device_slot),
                } });
            }
            return;
        }

        if (absDiff(delta, 0) < PinchJitterDeadzone) return;
        if (absDiff(delta, 0) < PinchEmitThreshold) return;

        state.last_pinch_delta = delta;
        try self.enqueue(.{ .pinch = .{
            .delta = delta,
            .scale_factor = scale_factor,
            .direction = if (delta > 0) .out else .in,
            .finger_count = self.fingerCountForDevice(device_slot),
        } });
    }

    fn updateThreeFingerSwipeState(self: *Self, device_slot: u16) !void {
        const state = try self.getOrCreateDeviceState(device_slot);
        const active = self.activeContactsForDevice(device_slot);

        if (state.scroll_locked or state.multitouch_scroll_active or state.pinch_locked) {
            try self.endSwipe3(state);
            return;
        }

        if (active != 3) {
            try self.endSwipe3(state);
            return;
        }

        const cx = self.averagePositionXForDevice(device_slot);
        const cy = self.averagePositionYForDevice(device_slot);
        const step_dx = accelerateVelocity(cx - self.averagePrevPositionXForDevice(device_slot));
        const step_dy = accelerateVelocity(cy - self.averagePrevPositionYForDevice(device_slot));

        const total_dx = cx - state.swipe3_start_cx;
        const total_dy = cy - state.swipe3_start_cy;

        if (!state.swipe3_locked) {
            state.swipe3_axis_candidate = chooseAxisCandidate(total_dx, total_dy);

            if (state.swipe3_arbitrating and state.swipe3_guard_frames > 0) {
                Self.tickSwipe3Guard(state);
            }

            const axis = if (state.swipe3_axis_candidate != .none) state.swipe3_axis_candidate else chooseAxisLock(total_dx, total_dy);
            const locked_total = applyAxisLock(axis, total_dx, total_dy);

            if (absDiff(locked_total.dx, 0) >= ThreeFingerSwipeActivateThreshold or absDiff(locked_total.dy, 0) >= ThreeFingerSwipeActivateThreshold) {
                state.swipe3_locked = true;
                state.swipe3_arbitrating = false;
                state.swipe3_guard_frames = 0;
                state.swipe3_axis_lock = axis;
                const initial_step = applyAxisLock(axis, step_dx, step_dy);
                state.last_swipe3_dx = initial_step.dx;
                state.last_swipe3_dy = initial_step.dy;
                const confidence = computeConfidence(locked_total.dx, locked_total.dy, axis);
                try self.enqueue(.{ .three_finger_swipe_begin = .{
                    .dx = initial_step.dx,
                    .dy = initial_step.dy,
                    .total_dx = locked_total.dx,
                    .total_dy = locked_total.dy,
                    .axis_locked = axis,
                    .confidence = confidence,
                    .finger_count = self.fingerCountForDevice(device_slot),
                } });
                try self.enqueue(.{ .intent_hint = .{
                    .gesture = .three_finger_swipe,
                    .axis = axisLockToAxis(axis),
                    .confidence = confidence,
                    .finger_count = self.fingerCountForDevice(device_slot),
                } });
            }
            return;
        }

        const locked_step = applyAxisLock(state.swipe3_axis_lock, step_dx, step_dy);
        const smoothed = try self.smoothSwipe3(device_slot, locked_step.dx, locked_step.dy);
        if (absDiff(smoothed.dx, 0) < ThreeFingerSwipeEmitThreshold and absDiff(smoothed.dy, 0) < ThreeFingerSwipeEmitThreshold) return;

        const locked_total = applyAxisLock(state.swipe3_axis_lock, total_dx, total_dy);
        const confidence = computeConfidence(locked_total.dx, locked_total.dy, state.swipe3_axis_lock);
        try self.enqueue(.{ .three_finger_swipe = .{
            .dx = smoothed.dx,
            .dy = smoothed.dy,
            .total_dx = locked_total.dx,
            .total_dy = locked_total.dy,
            .axis_locked = state.swipe3_axis_lock,
            .confidence = confidence,
            .finger_count = self.fingerCountForDevice(device_slot),
        } });
    }

    fn updateMultitouchScrollState(self: *Self, device_slot: u16) !void {
        const active_count = self.activeContactsForDevice(device_slot);
        const state = try self.getOrCreateDeviceState(device_slot);
        const was_locked = state.scroll_locked;

        if (active_count < 2) {
            if (was_locked or state.multitouch_scroll_active) {
                try self.endScrollWithCooldown(state);
            } else {
                Self.tickCooldown(state);
            }
            if (active_count == 0) Self.clearHighLevelLocks(state);
            return;
        }

        if (active_count == 3 or state.swipe3_locked or state.swipe3_arbitrating) {
            state.multitouch_scroll_active = false;
            state.scroll_locked = false;
            state.release_counter = 0;
            return;
        }

        const vx = self.averageVelocityXForDevice(device_slot);
        const vy = self.averageVelocityYForDevice(device_slot);
        const mag = @max(absDiff(vx, 0), absDiff(vy, 0));
        const coherent = self.contactsSupportScroll(device_slot) and axisDominant(vx, vy);

        if (!state.scroll_locked) {
            if (state.post_scroll_cooldown_frames > 0) {
                state.multitouch_scroll_active = false;
                return;
            }

            if (!state.pinch_locked and coherent and mag >= ScrollActivateThreshold) {
                state.multitouch_scroll_active = true;
                state.scroll_locked = true;
                state.release_counter = 0;
                try self.enqueue(.{ .scroll_begin = .{ .finger_count = self.fingerCountForDevice(device_slot) } });
                const axis_lock: LibsemainputOutput.AxisLock =
                    if (absDiff(vx, 0) > absDiff(vy, 0)) .horizontal else .vertical;
                try self.enqueue(.{ .intent_hint = .{
                    .gesture = .two_finger_scroll,
                    .axis = axisLockToAxis(axis_lock),
                    .confidence = computeConfidence(vx, vy, axis_lock),
                    .finger_count = self.fingerCountForDevice(device_slot),
                } });
            } else {
                state.multitouch_scroll_active = false;
            }
            return;
        }

        state.multitouch_scroll_active = true;

        if (!coherent or mag < ScrollReleaseThreshold) {
            state.release_counter += 1;
        } else {
            state.release_counter = 0;
        }

        if (state.release_counter >= ScrollReleaseFrames) {
            try self.endScrollWithCooldown(state);
        }
    }

    fn maybeEmitTwoFingerScroll(self: *Self, device_slot: u16) !void {
        const active_count = self.activeContactsForDevice(device_slot);
        const state = try self.getOrCreateDeviceState(device_slot);
        if (active_count < 2 or !state.multitouch_scroll_active or !state.scroll_locked) return;

        const vx = self.averageVelocityXForDevice(device_slot);
        const vy = self.averageVelocityYForDevice(device_slot);
        const smoothed = try self.smoothScroll(device_slot, vx, vy);

        if (absDiff(smoothed.dx, 0) <= ScrollEmitThreshold and absDiff(smoothed.dy, 0) <= ScrollEmitThreshold) return;

        try self.enqueue(.{ .two_finger_scroll = .{
            .dx = smoothed.dx,
            .dy = smoothed.dy,
            .finger_count = self.fingerCountForDevice(device_slot),
        } });
    }

    // ========================================================================
    // Touch event handlers
    // ========================================================================

    fn handleTouchDown(self: *Self, e: LibsemainputInput.Touch) !void {
        const c = try self.getOrCreateContact(e.device_slot, e.contact_id);
        c.is_active = true;
        c.start_x = e.x;
        c.start_y = e.y;
        c.prev_x = e.x;
        c.prev_y = e.y;
        c.last_x = e.x;
        c.last_y = e.y;
        c.down_ns = e.ts_ns;
        c.drag_started = false;
        _ = try self.getOrCreateDeviceState(e.device_slot);

        try self.enforceStrictArbitration(e.device_slot);
    }

    fn handleTouchMove(self: *Self, e: LibsemainputInput.Touch) !void {
        const c = try self.getOrCreateContact(e.device_slot, e.contact_id);
        if (!c.is_active) return;

        c.prev_x = c.last_x;
        c.prev_y = c.last_y;
        c.last_x = e.x;
        c.last_y = e.y;

        const state = try self.getOrCreateDeviceState(e.device_slot);

        if (state.post_scroll_cooldown_frames > 0) {
            Self.tickCooldown(state);
            return;
        }

        try self.enforceStrictArbitration(e.device_slot);

        if (state.swipe3_arbitrating and !state.swipe3_locked) {
            try self.updateThreeFingerSwipeState(e.device_slot);
            return;
        }

        try self.updateThreeFingerSwipeState(e.device_slot);
        if (state.swipe3_locked) return;

        try self.updatePinchState(e.device_slot);
        if (state.pinch_locked) return;

        try self.updateMultitouchScrollState(e.device_slot);
        try self.maybeEmitTwoFingerScroll(e.device_slot);
        if (state.scroll_locked or state.multitouch_scroll_active) return;

        const dx = absDiff(c.start_x, e.x);
        const dy = absDiff(c.start_y, e.y);

        if (!c.drag_started and (dx >= DragThreshold or dy >= DragThreshold)) {
            c.drag_started = true;
            try self.enqueue(.{ .drag_start = .{
                .contact_id = e.contact_id,
                .x = e.x,
                .y = e.y,
                .finger_count = self.fingerCountForDevice(e.device_slot),
            } });
        } else if (c.drag_started) {
            try self.enqueue(.{ .drag_move = .{
                .contact_id = e.contact_id,
                .x = e.x,
                .y = e.y,
                .finger_count = self.fingerCountForDevice(e.device_slot),
            } });
        }
    }

    fn handleTouchUp(self: *Self, e: LibsemainputInput.TouchUp) !void {
        const c = self.findContact(e.device_slot, e.contact_id) orelse return;
        if (!c.is_active) return;

        const state = try self.getOrCreateDeviceState(e.device_slot);
        const duration = e.ts_ns - c.down_ns;
        const dx = absDiff(c.start_x, c.last_x);
        const dy = absDiff(c.start_y, c.last_y);

        if (!state.scroll_locked and !state.multitouch_scroll_active and !state.pinch_locked and !state.swipe3_locked and !state.swipe3_arbitrating and state.post_scroll_cooldown_frames == 0) {
            if (c.drag_started) {
                try self.enqueue(.{ .drag_end = .{
                    .contact_id = e.contact_id,
                    .x = c.last_x,
                    .y = c.last_y,
                    .finger_count = self.fingerCountForDevice(e.device_slot),
                } });
            } else if (duration <= TapMaxDurationNs and dx < DragThreshold and dy < DragThreshold) {
                try self.enqueue(.{ .tap = .{
                    .contact_id = e.contact_id,
                    .x = c.last_x,
                    .y = c.last_y,
                    .finger_count = self.fingerCountForDevice(e.device_slot),
                } });
            }
        }

        c.is_active = false;
        c.drag_started = false;

        try self.enforceStrictArbitration(e.device_slot);
        try self.updateMultitouchScrollState(e.device_slot);
    }

    // ========================================================================
    // N-click recogniser
    // ========================================================================
    //
    // Per-device state machine that observes pointer_button events
    // and emits n_click when the same button is clicked multiple
    // times within a short interval at approximately the same
    // position. The library only emits the n-click layer; raw
    // pointer_button events are the caller's responsibility.

    fn findClickHistory(self: *Self, device_slot: u16) ?*ClickHistory {
        for (self.click_history.items) |*h| {
            if (h.device_slot == device_slot) return h;
        }
        return null;
    }

    fn insertClickHistory(self: *Self, device_slot: u16, button: u32) !*ClickHistory {
        try self.click_history.append(self.allocator, .{
            .device_slot = device_slot,
            .button = button,
            .x = 0,
            .y = 0,
            .ts_audio_samples = 0,
            .ts_wall_ns = 0,
            .down_x = 0,
            .down_y = 0,
            .count = 0,
        });
        return &self.click_history.items[self.click_history.items.len - 1];
    }

    fn handlePointerButton(self: *Self, e: LibsemainputInput.PointerButton) !void {
        if (e.pressed) {
            // Down event — record the press position so we can enforce
            // the click-vs-drag check on the matching up event.
            const h = self.findClickHistory(e.device_slot) orelse try self.insertClickHistory(e.device_slot, e.button);
            h.down_x = e.x;
            h.down_y = e.y;
            return;
        }

        // Up event — the click is now complete.
        const h = self.findClickHistory(e.device_slot) orelse {
            // Up without a prior down (started while we were not
            // watching). Record this as a count=1 click but do not
            // emit; we have no press position to validate against.
            const fresh = try self.insertClickHistory(e.device_slot, e.button);
            fresh.x = e.x;
            fresh.y = e.y;
            fresh.ts_wall_ns = e.ts_ns;
            fresh.ts_audio_samples = e.ts_audio_samples orelse 0;
            fresh.count = 1;
            return;
        };

        // Click-vs-drag: if the up event moved more than the radius
        // from the down event, this is a drag, not a click. Reset the
        // sequence so a future click does not chain off the abandoned
        // press. Do not emit.
        const radius_sq: i64 = @as(i64, NClickRadiusUnits) * @as(i64, NClickRadiusUnits);
        const drag_dist_sq = distSquared(e.x, e.y, h.down_x, h.down_y);
        if (drag_dist_sq > radius_sq) {
            h.count = 0;
            return;
        }

        // Determine whether the new click extends the existing
        // sequence. The sequence resets if any of: button differs,
        // time delta exceeds the threshold, or position moved more
        // than the radius from the previous click.
        var extends = h.count > 0 and h.button == e.button;
        if (extends) {
            if (e.ts_audio_samples) |samples_now| {
                if (h.ts_audio_samples == 0 or samples_now < h.ts_audio_samples) {
                    extends = false; // clock reset or out-of-order
                } else {
                    extends = (samples_now - h.ts_audio_samples) <= NClickIntervalSamples;
                }
            } else {
                // Audio clock unavailable; fall back to wall clock.
                extends = h.ts_wall_ns != 0 and e.ts_ns >= h.ts_wall_ns and (e.ts_ns - h.ts_wall_ns) <= NClickIntervalNs;
            }
        }
        if (extends) {
            const click_dist_sq = distSquared(e.x, e.y, h.x, h.y);
            if (click_dist_sq > radius_sq) extends = false;
        }

        if (extends) {
            h.count += 1;
        } else {
            h.button = e.button;
            h.count = 1;
        }
        h.x = e.x;
        h.y = e.y;
        h.ts_wall_ns = e.ts_ns;
        h.ts_audio_samples = e.ts_audio_samples orelse 0;

        // Emit n_click only when count >= 2. A single click is
        // already represented by the raw pointer_button events;
        // the recogniser exists to layer multi-click semantics
        // on top.
        if (h.count >= 2) {
            try self.enqueue(.{ .n_click = .{
                .button = e.button,
                .count = h.count,
                .x = e.x,
                .y = e.y,
                .finger_count = 1, // Pointer-driven gesture; not a touch.
            } });
        }
    }
};

// ============================================================================
// Tests
// ============================================================================

test "GestureRecognizer init/deinit clean" {
    const testing = std.testing;
    var r = GestureRecognizer.init(testing.allocator);
    defer r.deinit();
    try testing.expect(r.nextOutput() == null);
}

test "non-feeding inputs produce no outputs" {
    const testing = std.testing;
    var r = GestureRecognizer.init(testing.allocator);
    defer r.deinit();

    // pointer_motion and pointer_scroll do not feed any current
    // gesture in this recogniser; should produce nothing.
    try r.handleEvent(.{ .pointer_motion = .{ .device_slot = 0, .x = 100, .y = 100, .dx = 1, .dy = 0, .buttons = 0, .ts_ns = 1_000 } });
    try testing.expect(r.nextOutput() == null);

    try r.handleEvent(.{ .pointer_scroll = .{ .device_slot = 0, .dx = 0, .dy = 1, .ts_ns = 2_000 } });
    try testing.expect(r.nextOutput() == null);
}

test "single click does not emit n_click" {
    const testing = std.testing;
    var r = GestureRecognizer.init(testing.allocator);
    defer r.deinit();

    // press
    try r.handleEvent(.{ .pointer_button = .{ .device_slot = 0, .x = 100, .y = 100, .button = 0x1, .pressed = true, .ts_ns = 1_000_000 } });
    try testing.expect(r.nextOutput() == null);

    // release at same position
    try r.handleEvent(.{ .pointer_button = .{ .device_slot = 0, .x = 100, .y = 100, .button = 0x1, .pressed = false, .ts_ns = 50_000_000 } });
    // Single click: count becomes 1 internally but emits nothing
    // (n_click only fires at count >= 2).
    try testing.expect(r.nextOutput() == null);
}

test "double click emits n_click with count=2" {
    const testing = std.testing;
    var r = GestureRecognizer.init(testing.allocator);
    defer r.deinit();

    // First click.
    try r.handleEvent(.{ .pointer_button = .{ .device_slot = 0, .x = 100, .y = 100, .button = 0x1, .pressed = true, .ts_ns = 1_000_000 } });
    try r.handleEvent(.{ .pointer_button = .{ .device_slot = 0, .x = 100, .y = 100, .button = 0x1, .pressed = false, .ts_ns = 50_000_000 } });
    try testing.expect(r.nextOutput() == null);

    // Second click within 500ms at same position.
    try r.handleEvent(.{ .pointer_button = .{ .device_slot = 0, .x = 100, .y = 100, .button = 0x1, .pressed = true, .ts_ns = 200_000_000 } });
    try r.handleEvent(.{ .pointer_button = .{ .device_slot = 0, .x = 100, .y = 100, .button = 0x1, .pressed = false, .ts_ns = 250_000_000 } });

    const out = r.nextOutput();
    try testing.expect(out != null);
    try testing.expectEqual(@as(u32, 2), out.?.n_click.count);
    try testing.expectEqual(@as(u32, 0x1), out.?.n_click.button);
    try testing.expect(r.nextOutput() == null);
}

test "click separated by >500ms does not extend sequence" {
    const testing = std.testing;
    var r = GestureRecognizer.init(testing.allocator);
    defer r.deinit();

    try r.handleEvent(.{ .pointer_button = .{ .device_slot = 0, .x = 100, .y = 100, .button = 0x1, .pressed = true, .ts_ns = 1_000_000 } });
    try r.handleEvent(.{ .pointer_button = .{ .device_slot = 0, .x = 100, .y = 100, .button = 0x1, .pressed = false, .ts_ns = 50_000_000 } });
    while (r.nextOutput()) |_| {}

    const one_second = 1_000_000_000;
    try r.handleEvent(.{ .pointer_button = .{ .device_slot = 0, .x = 100, .y = 100, .button = 0x1, .pressed = true, .ts_ns = one_second } });
    try r.handleEvent(.{ .pointer_button = .{ .device_slot = 0, .x = 100, .y = 100, .button = 0x1, .pressed = false, .ts_ns = one_second + 50_000_000 } });

    // Fresh sequence; no n_click.
    try testing.expect(r.nextOutput() == null);
}

test "click far from previous starts new sequence" {
    const testing = std.testing;
    var r = GestureRecognizer.init(testing.allocator);
    defer r.deinit();

    // First click at (100, 100).
    try r.handleEvent(.{ .pointer_button = .{ .device_slot = 0, .x = 100, .y = 100, .button = 0x1, .pressed = true, .ts_ns = 1_000_000 } });
    try r.handleEvent(.{ .pointer_button = .{ .device_slot = 0, .x = 100, .y = 100, .button = 0x1, .pressed = false, .ts_ns = 50_000_000 } });

    // Second click 50 units away. NClickRadiusUnits = 8.
    try r.handleEvent(.{ .pointer_button = .{ .device_slot = 0, .x = 200, .y = 200, .button = 0x1, .pressed = true, .ts_ns = 200_000_000 } });
    try r.handleEvent(.{ .pointer_button = .{ .device_slot = 0, .x = 200, .y = 200, .button = 0x1, .pressed = false, .ts_ns = 250_000_000 } });

    try testing.expect(r.nextOutput() == null);
}

test "drag emits drag_start then drag_end (not tap)" {
    const testing = std.testing;
    var r = GestureRecognizer.init(testing.allocator);
    defer r.deinit();

    // Touch down at (100, 100).
    try r.handleEvent(.{ .touch_down = .{ .device_slot = 0, .contact_id = 0, .x = 100, .y = 100, .ts_ns = 1_000_000 } });
    try testing.expect(r.nextOutput() == null);

    // Move > DragThreshold (24) to (130, 100).
    try r.handleEvent(.{ .touch_move = .{ .device_slot = 0, .contact_id = 0, .x = 130, .y = 100, .ts_ns = 50_000_000 } });

    var saw_drag_start = false;
    while (r.nextOutput()) |out| {
        switch (out) {
            .drag_start => |p| {
                saw_drag_start = true;
                try testing.expectEqual(@as(i32, 130), p.x);
                try testing.expectEqual(@as(i32, 100), p.y);
            },
            else => {},
        }
    }
    try testing.expect(saw_drag_start);

    // Lift.
    try r.handleEvent(.{ .touch_up = .{ .device_slot = 0, .contact_id = 0, .ts_ns = 100_000_000 } });

    var saw_drag_end = false;
    var saw_tap = false;
    while (r.nextOutput()) |out| {
        switch (out) {
            .drag_end => saw_drag_end = true,
            .tap => saw_tap = true,
            else => {},
        }
    }
    try testing.expect(saw_drag_end);
    try testing.expect(!saw_tap);
}

test "quick small touch emits tap (not drag)" {
    const testing = std.testing;
    var r = GestureRecognizer.init(testing.allocator);
    defer r.deinit();

    try r.handleEvent(.{ .touch_down = .{ .device_slot = 0, .contact_id = 0, .x = 100, .y = 100, .ts_ns = 1_000_000 } });
    try r.handleEvent(.{ .touch_up = .{ .device_slot = 0, .contact_id = 0, .ts_ns = 50_000_000 } });

    var saw_tap = false;
    var saw_drag = false;
    while (r.nextOutput()) |out| {
        switch (out) {
            .tap => saw_tap = true,
            .drag_start, .drag_end => saw_drag = true,
            else => {},
        }
    }
    try testing.expect(saw_tap);
    try testing.expect(!saw_drag);
}

test "type sizes are reasonable" {
    const testing = std.testing;
    try testing.expect(@sizeOf(LibsemainputInput) <= 80);
    try testing.expect(@sizeOf(LibsemainputOutput) <= 80);
}

test "nextOutput drains FIFO order" {
    const testing = std.testing;
    var r = GestureRecognizer.init(testing.allocator);
    defer r.deinit();

    try r.enqueue(.{ .tap = .{ .contact_id = 0, .x = 1, .y = 1, .finger_count = 1 } });
    try r.enqueue(.{ .tap = .{ .contact_id = 0, .x = 2, .y = 2, .finger_count = 1 } });
    try r.enqueue(.{ .tap = .{ .contact_id = 0, .x = 3, .y = 3, .finger_count = 1 } });

    try testing.expectEqual(@as(i32, 1), r.nextOutput().?.tap.x);
    try testing.expectEqual(@as(i32, 2), r.nextOutput().?.tap.x);
    try testing.expectEqual(@as(i32, 3), r.nextOutput().?.tap.x);
    try testing.expect(r.nextOutput() == null);
}

test "finger_count populated on tap (single touch contact)" {
    // Per ADR 0017-rev2 addendum 2026-05-04, finger_count is the
    // one gesture-intrinsic field carried on every output variant.
    // A regression that left finger_count at 0 (default) wouldn't
    // be caught by the gesture-recognition tests above; this one
    // pins the population.
    //
    // Contract: finger_count is the active contact count at emit
    // time. handleTouchUp emits the tap event BEFORE marking the
    // contact inactive, so during emit there is still one active
    // contact (the one being lifted). A regression that reordered
    // those operations would change this value to 0 and the test
    // would fail loudly, prompting a review of the convention.
    const testing = std.testing;
    var r = GestureRecognizer.init(testing.allocator);
    defer r.deinit();

    try r.handleEvent(.{ .touch_down = .{ .device_slot = 0, .contact_id = 0, .x = 100, .y = 100, .ts_ns = 1_000_000 } });
    try r.handleEvent(.{ .touch_up = .{ .device_slot = 0, .contact_id = 0, .ts_ns = 50_000_000 } });

    var saw_tap = false;
    while (r.nextOutput()) |out| {
        switch (out) {
            .tap => |t| {
                saw_tap = true;
                try testing.expectEqual(@as(u8, 1), t.finger_count);
            },
            else => {},
        }
    }
    try testing.expect(saw_tap);
}
