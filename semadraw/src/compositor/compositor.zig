const std = @import("std");
const compat = @import("compat");
const damage = @import("damage");
const frame_scheduler = @import("frame_scheduler");
const backend_mod = @import("backend");
const surface_registry = @import("surface_registry");
const shared_clock = @import("shared_clock");
const input = @import("input");
const events = @import("events");

const log = std.log.scoped(.compositor);

/// ADR 0021 Section 7: presentation roots. lock is deliberately not
/// yet a member; it joins with the ADR 0012 implementation so no
/// dead selector arm exists before its machinery does.
pub const PresentationRoot = enum { scene, blank };

/// Compositor output configuration
pub const OutputConfig = struct {
    /// Output width in pixels
    width: u32 = 1920,
    /// Output height in pixels
    height: u32 = 1080,
    /// Pixel format
    format: backend_mod.PixelFormat = .rgba8,
    /// Target refresh rate
    refresh_hz: u32 = 60,
    /// Background color (RGBA, 0.0-1.0)
    background_color: [4]f32 = .{ 0.0, 0.0, 0.0, 1.0 },
    /// Backend type to use
    backend_type: backend_mod.BackendType = .software,
};

/// Composition state for a single output
pub const Output = struct {
    /// Output ID
    id: u32,
    /// Configuration
    config: OutputConfig,
    /// Backend for rendering
    be: backend_mod.Backend,
    /// Last composed frame
    last_frame: u64,
};

/// Compositor - orchestrates surface composition
pub const Compositor = struct {
    allocator: std.mem.Allocator,
    /// Surface registry reference
    surfaces: *surface_registry.SurfaceRegistry,

    /// ADR 0021 Section 7: the presentation-root selector. The
    /// composed output is chosen from a small set of roots by this
    /// value; the Section 3 (security, display) matrix is its truth
    /// table. Today: scene (normal client scene graph) and blank
    /// (compositor-owned fill, invariant B4). compose(lock) joins as
    /// a third root with the ADR 0012 machinery; Tier B display-off
    /// becomes a fourth outcome, not new renderer state.
    presentation_root: PresentationRoot = .scene,
    /// The blank root composes exactly one fill frame and then
    /// suspends: true once that frame has been presented. Reset on
    /// every entry to the blank root.
    blank_presented: bool = false,
    /// Warn-once latch for backends without clearRegion, where the
    /// blank fill cannot be painted (see blankComposite).
    blank_unsupported_warned: bool = false,
    /// Damage tracker
    damage_tracker: damage.DamageTracker,
    /// Wall clock source, owns the memory the ClockSource points into
    wall_clock: frame_scheduler.WallClockSource,
    /// Audio hardware clock source, when valid, drives the frame scheduler
    /// instead of the wall clock for drift-free AV synchronisation.
    chronofs_clock: ?frame_scheduler.ChronofsClockSource,
    /// Frame scheduler
    scheduler: frame_scheduler.FrameScheduler,
    /// Primary output
    output: ?Output,
    /// Composition state
    composing: bool,
    /// Statistics
    total_composites: u64,
    total_surfaces_composed: u64,
    /// AD-25: per-frame instrumentation gate. When true, composite()
    /// emits an `ad25_diagnostic` unified-schema event per cycle with
    /// clearRegion call counts, pixels cleared, time spent in
    /// clearRegion, and whether either fallback path triggered
    /// markFullRepaint. Set at init time from the
    /// UTF_COMPOSITOR_INSTRUMENT environment variable; absent or
    /// empty leaves it off and adds zero per-frame cost beyond a
    /// single bool check.
    instrument: bool,
    /// AD-25 Round 2 (ADR 0007 addendum): per-needsComposite gate
    /// instrumentation. When true, needsComposite() emits a
    /// `composite_gate_diagnostic` event on every call, recording
    /// has_damage and should_composite values plus a state_valid
    /// flag for the early-return paths. Set at init time from
    /// UTF_COMPOSITE_GATE_INSTRUMENT; same blk pattern as
    /// instrument above. Independent of `instrument` so each can
    /// be enabled separately.
    gate_instrument: bool,
    /// ADR 0020: frame pacing mode. .audio means the scheduler is wired to
    /// the adopted audio hardware clock; .wall means it has been rewired to
    /// the wall clock because the audio clock stalled, went invalid, or was
    /// absent. The mode toggles at runtime: a frozen adopted clock rewires to
    /// wall, and a wall fallback re-adopts audio once the sample counter
    /// resumes advancing, so AV-sync returns instead of degrading permanently
    /// after the first idle period.
    pacing_mode: PacingMode,
    /// ADR 0020: liveness mark for the audio clock. audio_samples_mark is the
    /// chronofs sample counter at the last observed advance (audio mode) or
    /// the last probe (wall mode); audio_wall_mark is the wall time at that
    /// observation. A counter frozen for GATE_STALL_REWIRE_NS of wall time is
    /// the stall; a counter that advances across a full
    /// READOPT_PROBE_INTERVAL_NS in wall mode is the resume.
    audio_samples_mark: u64,
    audio_wall_mark: i128,

    pub const PacingMode = enum { audio, wall };

    /// ADR 0020 (was AD-43.3a fix (c)): wall time the adopted clock may sit
    /// frozen before the watchdog rewires pacing to the wall clock. Thirty
    /// 60 Hz frame intervals: far above scheduler jitter, far below
    /// human-visible stall.
    const GATE_STALL_REWIRE_NS: i128 = 500 * std.time.ns_per_ms;
    /// ADR 0020: wall-mode re-adoption probe window. The audio sample counter
    /// must advance across a full interval before re-adopting, so the
    /// interval doubles as the dwell that rejects a single jitter tick. The
    /// read is non-blocking (samplePosition, not the isAdvancing 50 ms
    /// sleep), so this only bounds how often a resume is checked.
    const READOPT_PROBE_INTERVAL_NS: i128 = 250 * std.time.ns_per_ms;

    const Self = @This();

    pub fn init(
        allocator: std.mem.Allocator,
        surfaces: *surface_registry.SurfaceRegistry,
    ) Self {
        // The scheduler's ClockSource is wired to self.wall_clock in start()
        // once the Compositor is in its final memory location. We pass a
        // placeholder here; no clock call is made before start() is called.
        const placeholder_clock = frame_scheduler.ClockSource{
            .context = @ptrFromInt(1), // non-null sentinel, never dereferenced
            .nowFn = &placeholderNow,
        };
        return .{
            .allocator = allocator,
            .surfaces = surfaces,
            .damage_tracker = damage.DamageTracker.init(allocator),
            .wall_clock = frame_scheduler.WallClockSource.init(),
            .chronofs_clock = null,
            .scheduler = frame_scheduler.FrameScheduler.init(60, placeholder_clock),
            .output = null,
            .composing = false,
            .total_composites = 0,
            .total_surfaces_composed = 0,
            // AD-25: instrumentation gate. Reads UTF_COMPOSITOR_INSTRUMENT
            // at construction time. Any non-empty value enables; absent
            // or empty leaves it off. Reading once at construction means
            // zero per-frame syscall cost when off.
            .instrument = blk: {
                const v = compat.args.getenv("UTF_COMPOSITOR_INSTRUMENT") orelse break :blk false;
                break :blk v.len > 0;
            },
            // AD-25 Round 2: same init-time pattern for the
            // composite-gate diagnostic. Enabled by setting
            // UTF_COMPOSITE_GATE_INSTRUMENT to any non-empty value.
            .gate_instrument = blk: {
                const v = compat.args.getenv("UTF_COMPOSITE_GATE_INSTRUMENT") orelse break :blk false;
                break :blk v.len > 0;
            },
            .pacing_mode = .wall,
            .audio_samples_mark = 0,
            .audio_wall_mark = 0,
        };
    }

    fn placeholderNow(_: *anyopaque) i128 {
        // Should never be called, start() rewires the clock before any
        // scheduling query is made.
        @panic("FrameScheduler clock used before Compositor.start()");
    }

    pub fn deinit(self: *Self) void {
        if (self.output) |*out| {
            out.be.deinit();
        }
        self.damage_tracker.deinit();
    }

    /// Initialize output with given configuration.
    ///
    /// AD-17: after backend creation, asks the backend for its native
    /// display size. If the backend reports one and it differs from
    /// the configured `width`/`height`, the configuration is overridden
    /// and the backend's reported size becomes authoritative. The
    /// configured values become a fallback for backends that have no
    /// detection mechanism (software, headless) or that can't detect
    /// right now (drawfs without efifb available).
    ///
    /// `output.config` stores the resolved size, not the requested one,
    /// so subsequent compositor code (damage tracker, scheduler, etc.)
    /// reads consistent values.
    pub fn initOutput(self: *Self, id: u32, config: OutputConfig) !void {
        // Create backend
        var be = try backend_mod.createBackend(self.allocator, config.backend_type);
        errdefer be.deinit();

        // AD-17: prefer the backend's detected display size when available.
        var actual_config = config;
        if (be.getDetectedDisplaySize()) |size| {
            if (size.width != config.width or size.height != config.height) {
                log.info(
                    "backend reports display size {}x{}, overriding configured {}x{}",
                    .{ size.width, size.height, config.width, config.height },
                );
                actual_config.width = size.width;
                actual_config.height = size.height;
            }
        }

        // Initialize framebuffer with the resolved size
        try be.initFramebuffer(.{
            .width = actual_config.width,
            .height = actual_config.height,
            .format = actual_config.format,
        });

        self.output = .{
            .id = id,
            .config = actual_config,
            .be = be,
            .last_frame = 0,
        };

        self.scheduler.setTargetHz(actual_config.refresh_hz);
        self.damage_tracker.markFullRepaint();
    }

    /// Optionally install an audio hardware clock for drift-free scheduling.
    /// Call before start(). Non-fatal: if the clock path is invalid the
    /// compositor falls back to the wall clock.
    pub fn setChronofsClockPath(self: *Self, path: []const u8) void {
        self.chronofs_clock = frame_scheduler.ChronofsClockSource.init(path);
    }

    /// Start composition loop
    pub fn start(self: *Self) void {
        // AD-43.3a fix (c), adoption gate: prefer the audio hardware
        // clock only when valid AND advancing. chronofs validity
        // never resets and a frozen pacing clock parks the frame
        // deadline in a future that never arrives (2026-06-06
        // census: three composites in 30 s of motion on a fresh
        // boot whose engine had never clocked). Fall back to wall.
        if (self.chronofs_clock) |*cc| {
            if (!cc.isValid()) {
                log.info("frame pacing: wall clock (audio clock absent or invalid)", .{});
            } else if (!cc.isAdvancing()) {
                log.info("frame pacing: wall clock (audio clock valid but frozen; engine not clocking)", .{});
            } else {
                log.info("frame pacing: adopted audio hardware clock", .{});
                self.scheduler.clock = cc.source();
                self.scheduler.start();
                self.pacing_mode = .audio;
                self.audio_samples_mark = cc.samplePosition() orelse 0;
                self.audio_wall_mark = monotonicNowNs();
                self.composing = true;
                return;
            }
        } else {
            log.info("frame pacing: wall clock (no audio clock source configured)", .{});
        }
        // Rewire the scheduler's clock to point to self.wall_clock now that
        // the Compositor is in its final memory location.
        self.scheduler.clock = self.wall_clock.source();
        self.scheduler.start();
        self.pacing_mode = .wall;
        self.audio_samples_mark = if (self.chronofs_clock) |*cc| (cc.samplePosition() orelse 0) else 0;
        self.audio_wall_mark = monotonicNowNs();
        self.composing = true;
    }

    /// Stop composition loop
    pub fn stop(self: *Self) void {
        self.composing = false;
        self.scheduler.stop();
    }

    /// ADR 0021 Section 7: select the presentation root. Entering
    /// blank arms one fill frame; returning to scene marks a full
    /// repaint so the first woken frame rebuilds the whole scene
    /// (stale per-surface damage accumulated while blanked was
    /// discarded, see discardPendingDamage).
    pub fn setPresentationRoot(self: *Self, root: PresentationRoot) void {
        if (self.presentation_root == root) return;
        self.presentation_root = root;
        switch (root) {
            .blank => self.blank_presented = false,
            .scene => self.damage_tracker.markFullRepaint(),
        }
    }

    pub fn getPresentationRoot(self: *Self) PresentationRoot {
        return self.presentation_root;
    }

    /// ADR 0021 Section 7: while the blank root is presented, clients
    /// keep executing and may keep committing damage that will never
    /// be composited (the wake path full-repaints instead). Discard
    /// it so the damage tracker does not grow without bound across a
    /// long blank. Called by the daemon on blanked loop passes.
    pub fn discardPendingDamage(self: *Self) void {
        self.damage_tracker.clearAll();
    }

    /// Check if composition is needed
    pub fn needsComposite(self: *Self) bool {
        // AD-25 Round 2: the early-return paths represent
        // infrastructure-not-ready states (compositor stopped, output
        // not yet bound). They are not the gating cases of interest
        // for Round 2's question (why is composite gated during
        // active cursor motion?), but we emit state_valid=false here
        // so the analysis can count them and confirm they are rare.
        if (!self.composing) {
            if (self.gate_instrument) {
                events.emitCompositeGateDiagnostic(false, false, false);
            }
            return false;
        }
        if (self.output == null) {
            if (self.gate_instrument) {
                events.emitCompositeGateDiagnostic(false, false, false);
            }
            return false;
        }

        const has_damage = self.damage_tracker.hasDamage();
        const should_composite = self.scheduler.shouldComposite();

        // ADR 0020: keep the pacing clock live. Runs independent of pending
        // damage; the AD-43.3a predecessor only ran with damage pending,
        // which is exactly what blinded it to the idle freeze (no damage
        // while idle, so the watchdog never armed). Extracted so the
        // transition state machine is unit-testable with synthetic wall time;
        // see updatePacingLiveness.
        self.updatePacingLiveness(
            if (self.chronofs_clock) |*cc| cc.samplePosition() else null,
            monotonicNowNs(),
        );

        // ADR 0021 Section 7: the blank root composes exactly one
        // fill frame and then suspends the frame pipeline. Placed
        // after updatePacingLiveness so the ADR 0020 pacing-clock
        // machinery keeps running while blanked and wake resumes on
        // a live clock.
        if (self.presentation_root == .blank) {
            return !self.blank_presented;
        }

        if (has_damage and should_composite) {
            log.debug("needsComposite: damage={} scheduler={}", .{ has_damage, should_composite });
        }
        if (self.gate_instrument) {
            events.emitCompositeGateDiagnostic(has_damage, should_composite, true);
        }
        return has_damage and should_composite;
    }

    /// ADR 0020: pacing-clock liveness state machine. Given the current
    /// chronofs sample counter (null when the region is invalid) and the
    /// current wall time, keep the scheduler paced on a live clock: rewire a
    /// frozen or invalidated adopted audio clock to the wall clock, and
    /// re-adopt the audio clock once its counter resumes advancing across a
    /// full probe interval. scheduler.start() re-seeds next_deadline_ns in
    /// the new clock's epoch on every transition, so the first composite
    /// after a switch lands within one frame interval. Wall time is passed in
    /// rather than read here so the transitions are deterministically
    /// testable.
    fn updatePacingLiveness(self: *Self, cur_samples: ?u64, now_wall: i128) void {
        switch (self.pacing_mode) {
            .audio => {
                if (cur_samples) |s| {
                    if (s > self.audio_samples_mark) {
                        // Healthy: the adopted clock advanced. Refresh the mark.
                        self.audio_samples_mark = s;
                        self.audio_wall_mark = now_wall;
                    } else if (now_wall - self.audio_wall_mark > GATE_STALL_REWIRE_NS) {
                        // Frozen for the stall window: rewire to the wall clock.
                        log.warn("frame pacing clock stalled {d} ms (audio clock not advancing); rewiring to wall clock", .{@divTrunc(now_wall - self.audio_wall_mark, std.time.ns_per_ms)});
                        self.scheduler.clock = self.wall_clock.source();
                        self.scheduler.start();
                        self.pacing_mode = .wall;
                        self.audio_samples_mark = s;
                        self.audio_wall_mark = now_wall;
                    }
                } else {
                    // Region went invalid (writer gone): nothing to pace on,
                    // rewire immediately and reset the mark so any later
                    // resume reads as an advance.
                    log.warn("frame pacing clock invalidated; rewiring to wall clock", .{});
                    self.scheduler.clock = self.wall_clock.source();
                    self.scheduler.start();
                    self.pacing_mode = .wall;
                    self.audio_samples_mark = 0;
                    self.audio_wall_mark = now_wall;
                }
            },
            .wall => {
                // Re-adopt only after the sample counter advances across a
                // full probe interval, so the interval doubles as the dwell
                // that rejects a single jitter tick.
                if (now_wall - self.audio_wall_mark >= READOPT_PROBE_INTERVAL_NS) {
                    if (cur_samples) |s| {
                        if (s > self.audio_samples_mark) {
                            if (self.chronofs_clock) |*cc| {
                                log.info("frame pacing: re-adopted audio hardware clock (resumed advancing)", .{});
                                self.scheduler.clock = cc.source();
                                self.scheduler.start();
                                self.pacing_mode = .audio;
                            }
                        }
                        self.audio_samples_mark = s;
                    } else {
                        self.audio_samples_mark = 0;
                    }
                    self.audio_wall_mark = now_wall;
                }
            },
        }
    }

    /// ADR 0021 Section 7: compose the blank root. clearRegion is
    /// the fill mechanism; on a backend without it the fill cannot
    /// be painted and the pipeline still suspends with the last
    /// scene frame on the panel, which violates B4 on that backend
    /// and is warned loudly once. The platform backend (drawfs)
    /// implements clearRegion, so the bench never takes that arm.
    fn blankComposite(self: *Self, output: anytype, frame: anytype) !CompositeResult {
        if (output.be.supportsClearRegion()) {
            output.be.clearRegion(.{
                .framebuffer = .{
                    .width = output.config.width,
                    .height = output.config.height,
                    .format = output.config.format,
                },
                .x = 0,
                .y = 0,
                .width = output.config.width,
                .height = output.config.height,
                .color = output.config.background_color,
            }) catch |err| {
                log.warn("blank fill failed: {}; retrying next pass", .{err});
                return .{
                    .frame_number = frame.frame_number,
                    .surfaces_rendered = 0,
                    .total_render_time_ns = 0,
                    .frame_time_ns = frame.getElapsed(),
                    .target_audio_samples = null,
                };
            };
            // The fill is in the surface buffer; carry it to the
            // panel. Without this the blank root's writes wait for a
            // render blit that never comes (the pipeline suspends),
            // which was exactly the first bench symptom: transitions
            // and notifications firing, screen unchanged.
            output.be.flush();
        } else if (!self.blank_unsupported_warned) {
            self.blank_unsupported_warned = true;
            log.warn("backend lacks clearRegion: blank fill unavailable, panel keeps last frame (B4 violated on this backend)", .{});
        }

        self.blank_presented = true;
        self.damage_tracker.clearAll();
        self.total_composites += 1;
        output.last_frame = frame.frame_number;

        const target_samples: ?u64 = if (self.chronofs_clock) |*cc|
            cc.samplePosition()
        else
            null;

        return .{
            .frame_number = frame.frame_number,
            .surfaces_rendered = 0,
            .total_render_time_ns = 0,
            .frame_time_ns = frame.getElapsed(),
            .target_audio_samples = target_samples,
        };
    }

    /// Perform composition
    pub fn composite(self: *Self) !CompositeResult {
        const output = &(self.output orelse return error.NoOutput);

        var frame = self.scheduler.beginFrame();
        defer frame.end();

        // ADR 0021 Section 7: the blank root. One full-frame fill in
        // the background colour (invariant B4: a compositor-owned
        // fill, not a surface), then the pipeline suspends via the
        // needsComposite gate until the root changes.
        if (self.presentation_root == .blank) {
            return self.blankComposite(output, &frame);
        }

        self.damage_tracker.beginFrame();

        // Lock surfaces during composition to prevent use-after-free
        self.surfaces.beginComposition();
        defer self.surfaces.endComposition();

        // Get surfaces in composition order
        const composition_order = try self.surfaces.getCompositionOrder();

        log.debug("composite: {} surfaces in composition order, full_repaint={}", .{
            composition_order.len,
            self.damage_tracker.needs_full_repaint,
        });

        var surfaces_rendered: u32 = 0;
        var total_render_time: u64 = 0;

        // AD-21 sub-item 9 / region damage: consume any output-region
        // damage emitted since the last composite. Two paths:
        //
        //   - Backend supports clearRegion: call it once per damaged
        //     rect, painting the output background colour. Surfaces
        //     that intersect the damaged regions are expected to have
        //     their own damage marked by the producer (e.g. the AD-21
        //     pump's surface-damage walk), so they re-render and
        //     overwrite the cleared pixels with their content.
        //
        //   - Backend lacks clearRegion: fall back to a full-frame
        //     clear via `clear_color` on the first surface render,
        //     and mark a full repaint so every surface re-renders.
        //     Coarser, but correct.
        //
        // The full-repaint path remains the canonical "clear" trigger
        // (e.g. on first composite, geometry changes); region damage
        // is the addition for partial-update scenarios where surfaces
        // alone can't cover stale pixels.
        // The full-repaint path remains the canonical "clear" trigger
        // (e.g. on first composite, geometry changes); region damage
        // is the addition for partial-update scenarios where surfaces
        // alone can't cover stale pixels.

        // AD-25 instrumentation: per-frame counters for the clearRegion
        // block. Updated below alongside the existing logic; consumed
        // at end-of-composite when self.instrument is true. Defining
        // them unconditionally costs four stack slots per frame; the
        // condition gates only the log emission and the timing
        // syscalls.
        var instr_clear_calls: u32 = 0;
        var instr_clear_pixels: u64 = 0;
        var instr_clear_ns: u64 = 0;
        var instr_full_repaint_from_clear: bool = false;
        const instr_entered_with_full_repaint: bool = self.damage_tracker.needs_full_repaint;

        const output_damages = self.damage_tracker.output_damage.items;
        const have_region_damage = output_damages.len > 0;
        if (have_region_damage and !self.damage_tracker.needs_full_repaint) {
            if (output.be.supportsClearRegion()) {
                for (output_damages) |rect| {
                    const t0: i128 = if (self.instrument) monotonicNowNs() else 0;
                    output.be.clearRegion(.{
                        .framebuffer = .{
                            .width = output.config.width,
                            .height = output.config.height,
                            .format = output.config.format,
                        },
                        .x = rect.x,
                        .y = rect.y,
                        .width = rect.width,
                        .height = rect.height,
                        .color = output.config.background_color,
                    }) catch |err| {
                        log.warn("clearRegion failed: {}; falling back to full repaint", .{err});
                        self.damage_tracker.markFullRepaint();
                        instr_full_repaint_from_clear = true;
                        break;
                    };
                    if (self.instrument) {
                        const t1 = monotonicNowNs();
                        instr_clear_ns += @intCast(t1 - t0);
                        instr_clear_calls += 1;
                        instr_clear_pixels += @as(u64, rect.width) * @as(u64, rect.height);
                    }
                }
            } else {
                // Backend doesn't support partial clear. Promote to
                // full repaint so the full-frame clear path fires
                // and every surface re-renders to repaint itself.
                self.damage_tracker.markFullRepaint();
                instr_full_repaint_from_clear = true;
            }
        }

        // Clear with background color if full repaint
        const clear_color: ?[4]f32 = if (self.damage_tracker.needs_full_repaint)
            output.config.background_color
        else
            null;

        // AD-21 sub-item 10 / upper-z damage propagation: when a
        // lower-z surface re-renders this cycle, any visible higher-z
        // surface whose bounds intersect must also re-render. Otherwise
        // the lower-z render overwrites pixels at the intersection
        // without the higher-z surface re-painting on top, and the
        // higher-z surface visually disappears at those pixels until
        // it next has its own damage.
        //
        // Surfaced specifically as the AD-21 cursor surface
        // disappearing during cursor idle while semadraw-term
        // re-renders periodically: the cursor surface (z=1000000) had
        // no damage so the compositor skipped it; semadraw-term's
        // re-render then overwrote the cursor's pixels with its own
        // content, and the cursor was gone until the next pointer
        // move re-damaged it.
        //
        // The general rule: re-rendering a lower-z surface dirties
        // any higher-z visible surface whose bounds intersect. The
        // cursor case is just the first instance where it visibly
        // matters; the same fix applies to any future high-z
        // overlay (notifications, panels, drag previews, etc.).
        //
        // Bounds use logical_width/height at position_(x,y) in
        // framebuffer coordinates. composition_order is sorted
        // ascending by z (back to front), so surfaces strictly above
        // index i are at indices [i+1, len). Cost: O(N×M) where N is
        // damaged surfaces and M is surfaces above each. For small N
        // and M (typical workloads), this is fine; spatial indexing
        // could make it sub-linear if profiling shows it matters.
        //
        // The propagation runs only when at least one surface has
        // damage and some surface is above it; otherwise the inner
        // loop never executes. Skipped entirely when needs_full_repaint
        // is set (everything renders anyway).
        if (!self.damage_tracker.needs_full_repaint) {
            for (composition_order, 0..) |lower, i| {
                if (!lower.current.visible) continue;
                const lower_dam = self.damage_tracker.getSurfaceDamage(lower.id);
                const lower_damaged = lower_dam != null and lower_dam.?.hasDamage();
                if (!lower_damaged) continue;

                const lower_rect: damage.Rect = .{
                    .x = @intFromFloat(lower.current.position_x),
                    .y = @intFromFloat(lower.current.position_y),
                    .width = @intFromFloat(@max(0.0, lower.current.logical_width)),
                    .height = @intFromFloat(@max(0.0, lower.current.logical_height)),
                };
                if (lower_rect.isEmpty()) continue;

                for (composition_order[i + 1 ..]) |upper| {
                    if (!upper.current.visible) continue;
                    const upper_rect: damage.Rect = .{
                        .x = @intFromFloat(upper.current.position_x),
                        .y = @intFromFloat(upper.current.position_y),
                        .width = @intFromFloat(@max(0.0, upper.current.logical_width)),
                        .height = @intFromFloat(@max(0.0, upper.current.logical_height)),
                    };
                    if (upper_rect.isEmpty()) continue;

                    if (lower_rect.intersects(upper_rect)) {
                        self.damage_tracker.markSurfaceFullDamage(upper.id) catch |err| {
                            log.warn("upper-z damage propagation failed for surface {}: {}", .{ upper.id, err });
                        };
                    }
                }
            }
        }

        // Render each visible surface
        for (composition_order) |surface| {
            if (!surface.current.visible) {
                log.debug("  surface {}: skipped (not visible)", .{surface.id});
                continue;
            }

            // Check if surface has damage
            const surface_damaged = self.damage_tracker.needs_full_repaint or
                (self.damage_tracker.getSurfaceDamage(surface.id) != null and
                self.damage_tracker.getSurfaceDamage(surface.id).?.hasDamage());

            if (!surface_damaged) {
                log.debug("  surface {}: skipped (no damage)", .{surface.id});
                continue;
            }

            // Get SDCS data from attached buffer
            const sdcs_data = if (surface.buffer) |*buf| buf.map() catch |err| blk: {
                log.warn("  surface {}: buffer map failed: {}", .{ surface.id, err });
                break :blk null;
            } else blk: {
                log.debug("  surface {}: no buffer attached", .{surface.id});
                break :blk null;
            };
            if (sdcs_data == null) continue;

            log.debug("  surface {}: rendering {} bytes SDCS data", .{ surface.id, sdcs_data.?.len });

            // AD-43 fix path 2: clip this surface's re-execution to
            // its damage bounding box (surface-local regions offset to
            // framebuffer coordinates). Full repaint frames and
            // full-damage surfaces pass null (no clip), preserving the
            // pre-existing behaviour bit for bit in those cases. The
            // win is the common frame: cursor-move damage of a few
            // hundred pixels no longer re-renders a 4K surface, and
            // the backend's blit damage stays small with it.
            const off_x: i32 = @intFromFloat(surface.current.position_x);
            const off_y: i32 = @intFromFloat(surface.current.position_y);
            const clip: ?backend_mod.ClipRect = blk: {
                if (self.damage_tracker.needs_full_repaint) break :blk null;
                const sd = self.damage_tracker.getSurfaceDamage(surface.id) orelse break :blk null;
                const bb = sd.boundingBox() orelse break :blk null;
                break :blk .{
                    .x = bb.x + off_x,
                    .y = bb.y + off_y,
                    .width = bb.width,
                    .height = bb.height,
                };
            };

            // Render surface at its position
            const result = try output.be.render(.{
                .surface_id = surface.id,
                .sdcs_data = sdcs_data.?,
                .framebuffer = .{
                    .width = output.config.width,
                    .height = output.config.height,
                    .format = output.config.format,
                },
                .clear_color = if (surfaces_rendered == 0) clear_color else null,
                .offset_x = off_x,
                .offset_y = off_y,
                .clip = clip,
            });

            if (result.error_msg == null) {
                surfaces_rendered += 1;
                total_render_time += result.render_time_ns;
                self.damage_tracker.clearSurfaceDamage(surface.id);
                log.debug("  surface {}: rendered successfully in {}ns", .{ surface.id, result.render_time_ns });
            } else {
                log.warn("  surface {}: render failed: {s}", .{ surface.id, result.error_msg.? });
            }
        }

        // Clear global damage
        // AD-25 instrumentation: emit a structured ad25_diagnostic
        // event in unified-schema format. See events.emitAd25Diagnostic
        // for field semantics. Gated on self.instrument so the per-cycle
        // emission cost (one bufPrint plus one writev) only fires when
        // the operator opts in via UTF_COMPOSITOR_INSTRUMENT.
        if (self.instrument) {
            events.emitAd25Diagnostic(
                self.total_composites,
                instr_clear_calls,
                instr_clear_pixels,
                instr_clear_ns,
                instr_entered_with_full_repaint,
                instr_full_repaint_from_clear,
                surfaces_rendered,
                total_render_time,
            );
        }

        self.damage_tracker.clearAll();

        self.total_composites += 1;
        self.total_surfaces_composed += surfaces_rendered;
        output.last_frame = frame.frame_number;

        // Capture the audio sample position for this frame boundary.
        const target_samples: ?u64 = if (self.chronofs_clock) |*cc|
            cc.samplePosition()
        else
            null;

        return .{
            .frame_number = frame.frame_number,
            .surfaces_rendered = surfaces_rendered,
            .total_render_time_ns = total_render_time,
            .frame_time_ns = frame.getElapsed(),
            .target_audio_samples = target_samples,
        };
    }

    /// Mark surface as damaged (full surface)
    pub fn damageSurface(self: *Self, surface_id: u32) !void {
        try self.damage_tracker.markSurfaceFullDamage(surface_id);
    }

    /// Mark rectangular region as damaged
    pub fn damageRegion(self: *Self, surface_id: u32, rect: damage.Rect) !void {
        try self.damage_tracker.addSurfaceDamage(surface_id, rect);
    }

    /// AD-21 sub-item 9 / region damage: mark a framebuffer-coordinate
    /// rectangle as damaged, independent of any surface. The compositor
    /// clears the rect to the output's background color at the start
    /// of the next composite cycle, before any surface renders. Used
    /// by the cursor position pump to wipe the cursor's old position
    /// when no underlying surface covers the area (the surface-damage
    /// walk in the pump catches surfaces; this catches no-surface
    /// regions).
    pub fn damageOutputRegion(self: *Self, rect: damage.Rect) !void {
        try self.damage_tracker.addOutputDamage(rect);
    }

    /// AD-21 sub-item 9 follow-up: report the active output's
    /// framebuffer dimensions, or null if no output has been
    /// initialised yet. The compositor's output config can differ
    /// from the daemon's configured dimensions when the backend
    /// reports a different native display size and the compositor
    /// overrides the configured value (see initOutput's AD-17
    /// handling). Callers needing framebuffer-coordinate bounds
    /// (e.g. the cursor position pump's visibility check) must
    /// read this rather than the daemon-side config to avoid
    /// using stale dimensions.
    pub fn outputDimensions(self: *const Self) ?backend_mod.DisplaySize {
        const out = self.output orelse return null;
        return .{ .width = out.config.width, .height = out.config.height };
    }

    /// CAPTURE-DESIGN.md commit 3: one coherent snapshot of the
    /// composited frame from the active backend, or null before
    /// initOutput or when the backend cannot produce one. The
    /// backend.FrameSnapshot atomicity and lifetime contract applies
    /// to the caller of this method identically: the pixels are a
    /// borrow, valid until the next mutating backend operation,
    /// never retained beyond the current event-loop turn.
    pub fn frameSnapshot(self: *const Self) ?backend_mod.FrameSnapshot {
        const out = self.output orelse return null;
        return out.be.frameSnapshot();
    }

    /// Mark entire output as needing repaint
    pub fn damageAll(self: *Self) void {
        self.damage_tracker.markFullRepaint();
    }

    /// Handle surface creation
    pub fn onSurfaceCreated(self: *Self, surface_id: u32) !void {
        try self.damage_tracker.markSurfaceFullDamage(surface_id);
    }

    /// Handle surface destruction
    pub fn onSurfaceDestroyed(self: *Self, surface_id: u32) void {
        self.damage_tracker.removeSurface(surface_id);
        // Damage the area where surface was (would need position tracking)
        self.damage_tracker.markFullRepaint();
    }

    /// Handle surface commit
    pub fn onSurfaceCommit(self: *Self, surface_id: u32) !void {
        // Full surface damage on commit (could be optimized with explicit damage)
        try self.damage_tracker.markSurfaceFullDamage(surface_id);
    }

    /// Get output framebuffer pixels
    pub fn getPixels(self: *Self) ?[]u8 {
        if (self.output) |*out| {
            return out.be.getPixels();
        }
        return null;
    }

    /// Get frame scheduler statistics
    pub fn getStats(self: *const Self) CompositorStats {
        return .{
            .frame_stats = self.scheduler.getStats(),
            .total_composites = self.total_composites,
            .total_surfaces_composed = self.total_surfaces_composed,
            .damage_regions = @intCast(self.damage_tracker.output_damage.items.len),
        };
    }

    /// Wait for next vsync deadline
    pub fn waitForVsync(self: *Self) void {
        self.scheduler.waitForDeadline();
    }

    /// Get time until next vsync
    pub fn getTimeUntilVsync(self: *const Self) i64 {
        return self.scheduler.getTimeUntilDeadline();
    }

    /// Poll backend for events (keyboard, window close, etc.)
    /// Returns false if backend should stop (e.g., X11 window closed)
    pub fn pollEvents(self: *Self) bool {
        if (self.output) |*out| {
            return out.be.pollEvents();
        }
        return true;
    }

    /// Get pending key events from backend
    pub fn getKeyEvents(self: *Self) []const backend_mod.KeyEvent {
        if (self.output) |*out| {
            return out.be.getKeyEvents();
        }
        return &[_]backend_mod.KeyEvent{};
    }

    /// Get pending mouse events from backend
    pub fn getMouseEvents(self: *Self) []const backend_mod.MouseEvent {
        if (self.output) |*out| {
            return out.be.getMouseEvents();
        }
        return &[_]backend_mod.MouseEvent{};
    }

    /// AD-2a Phase 2.4.2: get pending raw inputfs events from the
    /// backend's side-channel buffer. semadrawd uses this in
    /// Phase 2.4.4 to feed the gesture recogniser. Backends without
    /// inputfs integration return an empty slice.
    pub fn getInputfsEvents(self: *Self) []const input.Event {
        if (self.output) |*out| {
            return out.be.getInputfsEvents();
        }
        return &[_]input.Event{};
    }

    /// Return a file descriptor the daemon should include in its main
    /// poll() set, or null if the backend has no pollable event source.
    /// See backend.Backend.getPollFd for the rationale.
    pub fn getPollFd(self: *Self) ?std.posix.fd_t {
        if (self.output) |*out| {
            return out.be.getPollFd();
        }
        return null;
    }

    /// AD-41.3: return the inputfs notify fd if the backend integrates
    /// with inputfs. See backend.Backend.getInputfsPollFd for the
    /// rationale and inputfs/docs/adr/0021 for the architecture.
    pub fn getInputfsPollFd(self: *Self) ?std.posix.fd_t {
        if (self.output) |*out| {
            return out.be.getInputfsPollFd();
        }
        return null;
    }

    /// ADR 0009: drain the input wake descriptor's pending kevents.
    /// The wake fd's dispatch handler per the AD-32 rule.
    pub fn drainInputWake(self: *Self) void {
        if (self.output) |*out| {
            out.be.drainInputWake();
        }
    }

    /// Set clipboard content (selection: 0=CLIPBOARD, 1=PRIMARY)
    pub fn setClipboard(self: *Self, selection: u8, text: []const u8) !void {
        if (self.output) |*out| {
            return out.be.setClipboard(selection, text);
        }
        return error.NoOutput;
    }

    /// Request clipboard content (async - data available after pollEvents)
    pub fn requestClipboard(self: *Self, selection: u8) void {
        if (self.output) |*out| {
            out.be.requestClipboard(selection);
        }
    }

    /// Get clipboard data (returns null if not available)
    pub fn getClipboardData(self: *Self, selection: u8) ?[]const u8 {
        if (self.output) |*out| {
            return out.be.getClipboardData(selection);
        }
        return null;
    }

    /// Check if clipboard request is pending
    pub fn isClipboardPending(self: *Self) bool {
        if (self.output) |*out| {
            return out.be.isClipboardPending();
        }
        return false;
    }
};

/// Result of a composite operation
pub const CompositeResult = struct {
    frame_number: u64,
    surfaces_rendered: u32,
    total_render_time_ns: u64,
    frame_time_ns: u64,
    /// Audio sample position of this frame's target boundary.
    /// Non-null when the chronofs clock is driving the scheduler.
    target_audio_samples: ?u64,
};

/// Compositor statistics
pub const CompositorStats = struct {
    frame_stats: frame_scheduler.FrameStats,
    total_composites: u64,
    total_surfaces_composed: u64,
    damage_regions: u32,
};

// ============================================================================
// Tests
// ============================================================================

test "Compositor init" {
    var surfaces = surface_registry.SurfaceRegistry.init(std.testing.allocator);
    defer surfaces.deinit();

    var comp = Compositor.init(std.testing.allocator, &surfaces);
    defer comp.deinit();

    try std.testing.expect(!comp.composing);
    try std.testing.expect(comp.output == null);
}

test "Compositor rewires off a frozen audio clock and re-adopts on resume (ADR 0020)" {
    var surfaces = surface_registry.SurfaceRegistry.init(std.testing.allocator);
    defer surfaces.deinit();

    // A valid clock region so chronofs_clock is installed and the re-adoption
    // path has a real clock for scheduler.start() to read. The sample values
    // that drive the state machine are passed to updatePacingLiveness directly,
    // so the region contents do not affect the assertions.
    const tmp_path = "/tmp/sema_adr0020_pacing_test";
    {
        var writer = try shared_clock.ClockWriter.init(tmp_path);
        defer writer.deinit();
        writer.streamBegin(48_000);
        writer.update(48_000);
    }

    var comp = Compositor.init(std.testing.allocator, &surfaces);
    defer comp.deinit();
    comp.setChronofsClockPath(tmp_path);
    defer {
        if (comp.chronofs_clock) |*cc| cc.deinit();
    }

    // Enter audio-paced mode directly. start()'s adoption gate uses a 50 ms
    // isAdvancing probe against a live counter, which a static test region
    // cannot satisfy; the liveness state machine under test is independent of
    // how adoption was reached.
    comp.scheduler.clock = comp.chronofs_clock.?.source();
    comp.scheduler.start();
    comp.pacing_mode = .audio;
    comp.audio_samples_mark = 48_000;
    comp.audio_wall_mark = 0;

    const ms = std.time.ns_per_ms;

    // Healthy: the counter advances, mode stays audio, the mark refreshes.
    comp.updatePacingLiveness(48_800, 1 * ms);
    try std.testing.expectEqual(Compositor.PacingMode.audio, comp.pacing_mode);
    try std.testing.expectEqual(@as(u64, 48_800), comp.audio_samples_mark);

    // Frozen but still inside the stall window: stays audio.
    comp.updatePacingLiveness(48_800, 1 * ms + 100 * ms);
    try std.testing.expectEqual(Compositor.PacingMode.audio, comp.pacing_mode);

    // Frozen past GATE_STALL_REWIRE_NS of wall time: rewire to wall.
    comp.updatePacingLiveness(48_800, comp.audio_wall_mark + 501 * ms);
    try std.testing.expectEqual(Compositor.PacingMode.wall, comp.pacing_mode);

    // Wall mode: a single advancing tick before a full probe interval must not
    // re-adopt; the interval is the dwell.
    comp.updatePacingLiveness(49_600, comp.audio_wall_mark + 10 * ms);
    try std.testing.expectEqual(Compositor.PacingMode.wall, comp.pacing_mode);

    // Counter advanced across a full probe interval: re-adopt audio.
    comp.updatePacingLiveness(50_400, comp.audio_wall_mark + 300 * ms);
    try std.testing.expectEqual(Compositor.PacingMode.audio, comp.pacing_mode);
}

test "Compositor output init" {
    var surfaces = surface_registry.SurfaceRegistry.init(std.testing.allocator);
    defer surfaces.deinit();

    var comp = Compositor.init(std.testing.allocator, &surfaces);
    defer comp.deinit();

    try comp.initOutput(0, .{
        .width = 800,
        .height = 600,
        .format = .rgba8,
        .refresh_hz = 60,
    });

    try std.testing.expect(comp.output != null);
    try std.testing.expectEqual(@as(u32, 800), comp.output.?.config.width);
}

test "Compositor damage tracking" {
    var surfaces = surface_registry.SurfaceRegistry.init(std.testing.allocator);
    defer surfaces.deinit();

    var comp = Compositor.init(std.testing.allocator, &surfaces);
    defer comp.deinit();

    // Initial state has full repaint
    try std.testing.expect(comp.damage_tracker.hasDamage());

    comp.damage_tracker.clearAll();
    try std.testing.expect(!comp.damage_tracker.hasDamage());

    try comp.damageSurface(1);
    try std.testing.expect(comp.damage_tracker.hasDamage());
}

// ============================================================================
// Migration time idiom (P2 Tranche 2): file-local monotonic clock helper.
// Replaces std.time.nanoTimestamp(), removed in Zig 0.16. Monotonic is the
// correct clock for the interval/pacing maths here. Duplicated per file by
// design during migration; consolidation deferred.
// ============================================================================

fn monotonicNowNs() i128 {
    var ts: std.posix.timespec = undefined;
    _ = std.posix.system.clock_gettime(std.posix.CLOCK.MONOTONIC, &ts);
    return @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
}
