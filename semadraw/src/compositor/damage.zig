const std = @import("std");

/// Axis-aligned bounding box for damage regions
pub const Rect = struct {
    x: i32,
    y: i32,
    width: u32,
    height: u32,

    pub fn empty() Rect {
        return .{ .x = 0, .y = 0, .width = 0, .height = 0 };
    }

    pub fn isEmpty(self: Rect) bool {
        return self.width == 0 or self.height == 0;
    }

    /// Check if two rects intersect
    pub fn intersects(self: Rect, other: Rect) bool {
        if (self.isEmpty() or other.isEmpty()) return false;

        const self_right = self.x + @as(i32, @intCast(self.width));
        const self_bottom = self.y + @as(i32, @intCast(self.height));
        const other_right = other.x + @as(i32, @intCast(other.width));
        const other_bottom = other.y + @as(i32, @intCast(other.height));

        return self.x < other_right and
            self_right > other.x and
            self.y < other_bottom and
            self_bottom > other.y;
    }

    /// Compute union (bounding box) of two rects
    pub fn unionWith(self: Rect, other: Rect) Rect {
        if (self.isEmpty()) return other;
        if (other.isEmpty()) return self;

        const self_right = self.x + @as(i32, @intCast(self.width));
        const self_bottom = self.y + @as(i32, @intCast(self.height));
        const other_right = other.x + @as(i32, @intCast(other.width));
        const other_bottom = other.y + @as(i32, @intCast(other.height));

        const min_x = @min(self.x, other.x);
        const min_y = @min(self.y, other.y);
        const max_x = @max(self_right, other_right);
        const max_y = @max(self_bottom, other_bottom);

        return .{
            .x = min_x,
            .y = min_y,
            .width = @intCast(max_x - min_x),
            .height = @intCast(max_y - min_y),
        };
    }

    /// Compute intersection of two rects
    pub fn intersection(self: Rect, other: Rect) Rect {
        if (!self.intersects(other)) return Rect.empty();

        const self_right = self.x + @as(i32, @intCast(self.width));
        const self_bottom = self.y + @as(i32, @intCast(self.height));
        const other_right = other.x + @as(i32, @intCast(other.width));
        const other_bottom = other.y + @as(i32, @intCast(other.height));

        const max_x = @max(self.x, other.x);
        const max_y = @max(self.y, other.y);
        const min_right = @min(self_right, other_right);
        const min_bottom = @min(self_bottom, other_bottom);

        return .{
            .x = max_x,
            .y = max_y,
            .width = @intCast(min_right - max_x),
            .height = @intCast(min_bottom - max_y),
        };
    }

    /// Get area in pixels
    pub fn area(self: Rect) u64 {
        return @as(u64, self.width) * @as(u64, self.height);
    }
};

/// Per-surface damage tracking
pub const SurfaceDamage = struct {
    /// Surface ID
    surface_id: u32,
    /// Accumulated damage regions (in surface-local coordinates)
    regions: std.ArrayListUnmanaged(Rect),
    /// Full damage flag (entire surface needs redraw)
    full_damage: bool,
    /// Frame number when damage was added
    frame_added: u64,

    pub fn init(surface_id: u32) SurfaceDamage {
        return .{
            .surface_id = surface_id,
            .regions = .{},
            .full_damage = false,
            .frame_added = 0,
        };
    }

    pub fn deinit(self: *SurfaceDamage, allocator: std.mem.Allocator) void {
        self.regions.deinit(allocator);
    }

    /// Add a damage region
    pub fn addRegion(self: *SurfaceDamage, allocator: std.mem.Allocator, rect: Rect, frame: u64) !void {
        if (self.full_damage) return; // Already fully damaged

        // Merge with existing regions if they overlap significantly
        for (self.regions.items) |*existing| {
            if (rect.intersects(existing.*)) {
                const merged = existing.unionWith(rect);
                // If merge doesn't grow too much, use it
                if (merged.area() <= existing.area() + rect.area()) {
                    existing.* = merged;
                    self.frame_added = @max(self.frame_added, frame);
                    return;
                }
            }
        }

        // Add as new region
        try self.regions.append(allocator, rect);
        self.frame_added = @max(self.frame_added, frame);

        // If too many regions, convert to full damage
        if (self.regions.items.len > 32) {
            self.markFullDamage(frame);
        }
    }

    /// Mark entire surface as damaged
    pub fn markFullDamage(self: *SurfaceDamage, frame: u64) void {
        self.full_damage = true;
        self.regions.clearRetainingCapacity();
        self.frame_added = @max(self.frame_added, frame);
    }

    /// Clear all damage (after compositing)
    pub fn clear(self: *SurfaceDamage) void {
        self.regions.clearRetainingCapacity();
        self.full_damage = false;
    }

    /// Check if surface has any damage
    /// AD-43 fix path 2 (damage-clipped re-execution): bounding box
    /// of the accumulated regions, surface-local coordinates. Returns
    /// null when full_damage is set or no regions exist; callers
    /// treat null as "no clip" (full re-execution), which preserves
    /// today's behaviour exactly in the full-repaint case.
    pub fn boundingBox(self: *const SurfaceDamage) ?Rect {
        if (self.full_damage) return null;
        if (self.regions.items.len == 0) return null;
        var x0: i32 = std.math.maxInt(i32);
        var y0: i32 = std.math.maxInt(i32);
        var x1: i32 = std.math.minInt(i32);
        var y1: i32 = std.math.minInt(i32);
        for (self.regions.items) |r| {
            if (r.isEmpty()) continue;
            x0 = @min(x0, r.x);
            y0 = @min(y0, r.y);
            x1 = @max(x1, r.x + @as(i32, @intCast(r.width)));
            y1 = @max(y1, r.y + @as(i32, @intCast(r.height)));
        }
        if (x0 >= x1 or y0 >= y1) return null;
        return .{
            .x = x0,
            .y = y0,
            .width = @intCast(x1 - x0),
            .height = @intCast(y1 - y0),
        };
    }

    pub fn hasDamage(self: *const SurfaceDamage) bool {
        return self.full_damage or self.regions.items.len > 0;
    }

    /// Get bounding box of all damage
    pub fn getBounds(self: *const SurfaceDamage) Rect {
        if (self.regions.items.len == 0) return Rect.empty();

        var bounds = self.regions.items[0];
        for (self.regions.items[1..]) |r| {
            bounds = bounds.unionWith(r);
        }
        return bounds;
    }
};

/// Global damage tracker for all surfaces
pub const DamageTracker = struct {
    allocator: std.mem.Allocator,
    /// Per-surface damage
    surface_damage: std.AutoHashMap(u32, SurfaceDamage),
    /// Global output damage (after surface positioning)
    output_damage: std.ArrayListUnmanaged(Rect),
    /// Full repaint needed
    needs_full_repaint: bool,
    /// Current frame number
    current_frame: u64,

    pub fn init(allocator: std.mem.Allocator) DamageTracker {
        return .{
            .allocator = allocator,
            .surface_damage = std.AutoHashMap(u32, SurfaceDamage).init(allocator),
            .output_damage = .{},
            .needs_full_repaint = true, // Start with full repaint
            .current_frame = 0,
        };
    }

    pub fn deinit(self: *DamageTracker) void {
        var it = self.surface_damage.valueIterator();
        while (it.next()) |damage| {
            damage.deinit(self.allocator);
        }
        self.surface_damage.deinit();
        self.output_damage.deinit(self.allocator);
    }

    /// Begin a new frame
    pub fn beginFrame(self: *DamageTracker) void {
        self.current_frame += 1;
        // Note: output_damage is NOT cleared here. It is cleared by
        // clearAll() at the end of composite(), parallel to how
        // surface damage is consumed-and-cleared. Producers (e.g.
        // the AD-21 cursor position pump) emit output damage between
        // composites; clearing in beginFrame would lose it.
    }

    /// Add damage for a surface (surface-local coordinates)
    pub fn addSurfaceDamage(self: *DamageTracker, surface_id: u32, rect: Rect) !void {
        const entry = try self.surface_damage.getOrPut(surface_id);
        if (!entry.found_existing) {
            entry.value_ptr.* = SurfaceDamage.init(surface_id);
        }
        try entry.value_ptr.addRegion(self.allocator, rect, self.current_frame);
    }

    /// Mark entire surface as damaged
    pub fn markSurfaceFullDamage(self: *DamageTracker, surface_id: u32) !void {
        const entry = try self.surface_damage.getOrPut(surface_id);
        if (!entry.found_existing) {
            entry.value_ptr.* = SurfaceDamage.init(surface_id);
        }
        entry.value_ptr.markFullDamage(self.current_frame);
    }

    /// Mark entire output as needing repaint
    pub fn markFullRepaint(self: *DamageTracker) void {
        self.needs_full_repaint = true;
    }

    /// Check if any damage exists
    pub fn hasDamage(self: *const DamageTracker) bool {
        if (self.needs_full_repaint) return true;
        if (self.output_damage.items.len > 0) return true;

        var it = self.surface_damage.valueIterator();
        while (it.next()) |damage| {
            if (damage.hasDamage()) return true;
        }
        return false;
    }

    /// Get damage for a specific surface
    pub fn getSurfaceDamage(self: *DamageTracker, surface_id: u32) ?*SurfaceDamage {
        return self.surface_damage.getPtr(surface_id);
    }

    /// Clear surface damage (after compositing that surface)
    pub fn clearSurfaceDamage(self: *DamageTracker, surface_id: u32) void {
        if (self.surface_damage.getPtr(surface_id)) |damage| {
            damage.clear();
        }
    }

    /// Clear all damage (after full composition)
    pub fn clearAll(self: *DamageTracker) void {
        var it = self.surface_damage.valueIterator();
        while (it.next()) |damage| {
            damage.clear();
        }
        self.output_damage.clearRetainingCapacity();
        self.needs_full_repaint = false;
    }

    /// Remove damage tracking for a destroyed surface
    pub fn removeSurface(self: *DamageTracker, surface_id: u32) void {
        if (self.surface_damage.fetchRemove(surface_id)) |kv| {
            var damage = kv.value;
            damage.deinit(self.allocator);
        }
    }

    /// Add output damage region (global coordinates)
    pub fn addOutputDamage(self: *DamageTracker, rect: Rect) !void {
        try self.output_damage.append(self.allocator, rect);
    }

    /// Get output damage regions
    pub fn getOutputDamage(self: *DamageTracker) []const Rect {
        return self.output_damage.items;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "Rect intersection" {
    const r1 = Rect{ .x = 0, .y = 0, .width = 100, .height = 100 };
    const r2 = Rect{ .x = 50, .y = 50, .width = 100, .height = 100 };
    const r3 = Rect{ .x = 200, .y = 200, .width = 100, .height = 100 };

    try std.testing.expect(r1.intersects(r2));
    try std.testing.expect(!r1.intersects(r3));
}

test "Rect union" {
    const r1 = Rect{ .x = 0, .y = 0, .width = 100, .height = 100 };
    const r2 = Rect{ .x = 50, .y = 50, .width = 100, .height = 100 };

    const u = r1.unionWith(r2);
    try std.testing.expectEqual(@as(i32, 0), u.x);
    try std.testing.expectEqual(@as(i32, 0), u.y);
    try std.testing.expectEqual(@as(u32, 150), u.width);
    try std.testing.expectEqual(@as(u32, 150), u.height);
}

test "DamageTracker basic" {
    var tracker = DamageTracker.init(std.testing.allocator);
    defer tracker.deinit();

    try std.testing.expect(tracker.hasDamage()); // Initial full repaint

    tracker.clearAll();
    try std.testing.expect(!tracker.hasDamage());

    try tracker.addSurfaceDamage(1, .{ .x = 0, .y = 0, .width = 100, .height = 100 });
    try std.testing.expect(tracker.hasDamage());

    tracker.clearSurfaceDamage(1);
    try std.testing.expect(!tracker.hasDamage());
}

test "SurfaceDamage full damage threshold" {
    var damage = SurfaceDamage.init(1);
    defer damage.deinit(std.testing.allocator);

    // Add many regions to trigger full damage
    for (0..35) |i| {
        try damage.addRegion(std.testing.allocator, .{
            .x = @intCast(i * 10),
            .y = 0,
            .width = 5,
            .height = 5,
        }, 1);
    }

    try std.testing.expect(damage.full_damage);
}
