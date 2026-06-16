const std = @import("std");
const posix = std.posix;
const protocol = @import("protocol");

/// Surface state
pub const Surface = struct {
    id: protocol.SurfaceId,
    owner: protocol.ClientId,

    // AD-31.3: uid that owns this surface, populated at create time
    // from the creating client's peer_uid (Unix connections via
    // getpeereid, TCP connections as NOBODY_UID per ADR 0006 §2).
    // Daemon-created surfaces (the cursor surface) carry the
    // daemon's run_uid here so that no ordinary client matches
    // them.
    //
    // owner_uid never mutates over the surface's lifetime. When the
    // owning connection drops, the surface is destroyed; when the
    // last connection from this uid drops, no surface with this
    // owner_uid remains. Surface-modify permission checks compare
    // session.peer_uid against this field (with the configured
    // privileged uid bypassing the check). See ADR 0006 §§3-4.
    owner_uid: posix.uid_t,

    // Geometry
    logical_width: f32,
    logical_height: f32,
    position_x: f32 = 0,
    position_y: f32 = 0,
    z_order: i32 = 0,
    visible: bool = false,

    // Hotspot offset within the surface's sprite, in surface-local
    // pixels. Per ADR 0005 section 3, used by the cursor surface
    // so that the compositor can place the surface at
    // (pointer - hotspot) such that the sprite's hotspot pixel
    // lands on the actual pointer position. Defaults to (0, 0)
    // for ordinary surfaces; the daemon sets these explicitly on
    // the cursor surface during init and on every SET_CURSOR.
    //
    // The fields live on every Surface (rather than only on the
    // cursor) because they're cheap (8 bytes), they keep the
    // surface struct uniform, and a future hotspot-using feature
    // (e.g. drag-and-drop visual offsets) can use them without
    // a struct migration.
    hotspot_x: i32 = 0,
    hotspot_y: i32 = 0,

    // Attached buffer (if any)
    buffer: ?AttachedBuffer = null,

    // Frame state
    pending_commit: bool = false,
    frame_number: u64 = 0,

    pub fn getPixelCount(self: *const Surface) u64 {
        return @intFromFloat(@abs(self.logical_width * self.logical_height));
    }
};

/// Attached buffer - supports both shared memory (local) and inline data (remote)
pub const AttachedBuffer = struct {
    /// Shared memory file descriptor (-1 for inline buffers)
    shm_fd: posix.fd_t = -1,
    /// Size of the shared memory region
    shm_size: usize = 0,
    /// Mapped memory pointer (null if not yet mapped)
    mapped_ptr: ?*anyopaque = null,
    /// Offset into shm where SDCS data starts
    offset: usize = 0,
    /// Length of SDCS data
    length: usize,
    /// Inline data pointer (for remote connections, not owned by this struct)
    inline_data: ?[]const u8 = null,

    pub fn getData(self: *AttachedBuffer) ![]const u8 {
        // Return inline data if present (remote connections)
        if (self.inline_data) |data| {
            return data;
        }

        // Otherwise map shared memory (local connections)
        if (self.mapped_ptr) |p| {
            const byte_ptr: [*]u8 = @ptrCast(p);
            return byte_ptr[self.offset..][0..self.length];
        }

        const mapped = try posix.mmap(
            null,
            self.shm_size,
            .{ .READ = true },
            .{ .TYPE = .SHARED },
            self.shm_fd,
            0,
        );
        self.mapped_ptr = mapped.ptr;
        return mapped[self.offset..][0..self.length];
    }

    /// Legacy alias for getData
    pub fn map(self: *AttachedBuffer) ![]u8 {
        const data = try self.getData();
        // Cast away const for backwards compatibility
        return @constCast(data);
    }

    pub fn unmap(self: *AttachedBuffer) void {
        if (self.mapped_ptr) |p| {
            const byte_ptr: [*]align(4096) u8 = @ptrCast(@alignCast(p));
            posix.munmap(byte_ptr[0..self.shm_size]);
            self.mapped_ptr = null;
        }
    }

    pub fn deinit(self: *AttachedBuffer, allocator: std.mem.Allocator) void {
        self.unmap();
        if (self.shm_fd >= 0) {
            closeFd(self.shm_fd);
        }
        // inline_data is now always an owned allocation made by attachInlineBuffer
        // (both immediate and deferred paths copy the caller's data). Free it
        // here so disconnect-time cleanup releases the backing memory rather
        // than leaking it. Historically this slice was borrowed from the
        // client session's sdcs_buffer; that borrow caused use-after-free
        // segfaults when the session was destroyed before the next composite
        // consumed the slice.
        if (self.inline_data) |data| {
            allocator.free(data);
            self.inline_data = null;
        }
    }
};

/// Surface registry - manages all surfaces
pub const SurfaceRegistry = struct {
    allocator: std.mem.Allocator,
    surfaces: std.AutoHashMap(protocol.SurfaceId, *Surface),
    next_id: protocol.SurfaceId,

    // Composition order cache (sorted by z_order)
    composition_order: std.ArrayListUnmanaged(*Surface),
    order_dirty: bool,

    // Composition lock - prevents destructive operations during rendering
    compositing: bool,
    // Deferred destruction queue
    pending_destroy: std.ArrayListUnmanaged(protocol.SurfaceId),
    // Deferred buffer updates (surface_id -> new buffer data copy)
    pending_buffer_updates: std.AutoHashMap(protocol.SurfaceId, []u8),

    pub fn init(allocator: std.mem.Allocator) SurfaceRegistry {
        return .{
            .allocator = allocator,
            .surfaces = std.AutoHashMap(protocol.SurfaceId, *Surface).init(allocator),
            .next_id = 1,
            .composition_order = .empty,
            .order_dirty = false,
            .compositing = false,
            .pending_destroy = .empty,
            .pending_buffer_updates = std.AutoHashMap(protocol.SurfaceId, []u8).init(allocator),
        };
    }

    pub fn deinit(self: *SurfaceRegistry) void {
        // Free pending buffer updates
        var buf_it = self.pending_buffer_updates.valueIterator();
        while (buf_it.next()) |buf| {
            self.allocator.free(buf.*);
        }
        self.pending_buffer_updates.deinit();
        self.pending_destroy.deinit(self.allocator);

        var it = self.surfaces.valueIterator();
        while (it.next()) |surface_ptr| {
            if (surface_ptr.*.buffer) |*buf| {
                buf.deinit(self.allocator);
            }
            self.allocator.destroy(surface_ptr.*);
        }
        self.surfaces.deinit();
        self.composition_order.deinit(self.allocator);
    }

    /// Begin composition - prevents destructive operations
    pub fn beginComposition(self: *SurfaceRegistry) void {
        self.compositing = true;
    }

    /// End composition - processes deferred operations
    pub fn endComposition(self: *SurfaceRegistry) void {
        self.compositing = false;

        // Process pending buffer updates
        var buf_it = self.pending_buffer_updates.iterator();
        while (buf_it.next()) |entry| {
            const surface_id = entry.key_ptr.*;
            const new_data = entry.value_ptr.*;
            if (self.getSurface(surface_id)) |surface| {
                // Free old buffer
                if (surface.buffer) |*old_buf| {
                    old_buf.deinit(self.allocator);
                }
                // Set new inline buffer with copied data
                surface.buffer = .{
                    .length = new_data.len,
                    .inline_data = new_data,
                };
            } else {
                // Surface was destroyed, free the copied data
                self.allocator.free(new_data);
            }
        }
        self.pending_buffer_updates.clearRetainingCapacity();

        // Process pending destructions
        for (self.pending_destroy.items) |id| {
            self.destroySurfaceImmediate(id);
        }
        self.pending_destroy.clearRetainingCapacity();
    }

    /// Create a new surface
    pub fn createSurface(
        self: *SurfaceRegistry,
        owner: protocol.ClientId,
        owner_uid: posix.uid_t,
        width: f32,
        height: f32,
    ) !*Surface {
        const id = self.next_id;
        self.next_id += 1;

        const surface = try self.allocator.create(Surface);
        surface.* = .{
            .id = id,
            .owner = owner,
            .owner_uid = owner_uid,
            .logical_width = width,
            .logical_height = height,
        };

        try self.surfaces.put(id, surface);
        self.order_dirty = true;

        return surface;
    }

    /// Destroy a surface (deferred if compositing)
    pub fn destroySurface(self: *SurfaceRegistry, id: protocol.SurfaceId) void {
        if (self.compositing) {
            // Defer destruction until composition ends
            self.pending_destroy.append(self.allocator, id) catch return;
            // Mark as invisible immediately to prevent rendering
            if (self.getSurface(id)) |surface| {
                surface.visible = false;
            }
            self.order_dirty = true;
        } else {
            self.destroySurfaceImmediate(id);
        }
    }

    /// Destroy a surface immediately (internal use)
    fn destroySurfaceImmediate(self: *SurfaceRegistry, id: protocol.SurfaceId) void {
        if (self.surfaces.fetchRemove(id)) |kv| {
            const surface = kv.value;
            if (surface.buffer) |*buf| {
                buf.deinit(self.allocator);
            }
            self.allocator.destroy(surface);
            // Clear the cached composition order immediately to prevent
            // stale pointer dereference on the next composite call.
            self.composition_order.clearRetainingCapacity();
            self.order_dirty = true;
        }
    }

    /// Get a surface by ID
    pub fn getSurface(self: *SurfaceRegistry, id: protocol.SurfaceId) ?*Surface {
        return self.surfaces.get(id);
    }

    /// Attach a buffer to a surface
    pub fn attachBuffer(
        self: *SurfaceRegistry,
        surface_id: protocol.SurfaceId,
        shm_fd: posix.fd_t,
        shm_size: usize,
        offset: usize,
        length: usize,
    ) !void {
        const surface = self.getSurface(surface_id) orelse return error.SurfaceNotFound;

        // Clean up old buffer if present
        if (surface.buffer) |*old_buf| {
            old_buf.deinit(self.allocator);
        }

        surface.buffer = .{
            .shm_fd = shm_fd,
            .shm_size = shm_size,
            .offset = offset,
            .length = length,
        };
    }

    /// Attach inline buffer data to a surface (for remote connections)
    ///
    /// The caller's `data` slice is *always* copied. Both the deferred
    /// (compositing) and immediate (not compositing) paths now allocate a
    /// fresh copy that the surface owns. Historically the immediate path
    /// borrowed the slice; that borrow caused use-after-free segfaults
    /// when the client session's sdcs_buffer was freed (during disconnect)
    /// before the next composite consumed the slice.
    ///
    /// Ownership of the copied buffer transfers to the surface; it is
    /// freed via AttachedBuffer.deinit (which now takes an allocator
    /// parameter) when the surface is destroyed or the buffer replaced.
    pub fn attachInlineBuffer(
        self: *SurfaceRegistry,
        surface_id: protocol.SurfaceId,
        data: []const u8,
    ) !void {
        const surface = self.getSurface(surface_id) orelse return error.SurfaceNotFound;

        // Copy the caller's data unconditionally. The surface owns the copy.
        const data_copy = try self.allocator.alloc(u8, data.len);
        errdefer self.allocator.free(data_copy);
        @memcpy(data_copy, data);

        if (self.compositing) {
            // During composition, defer the buffer swap to apply-time so
            // the in-flight render doesn't pull the rug out from under
            // itself. Free any previous pending update for this surface.
            if (self.pending_buffer_updates.fetchRemove(surface_id)) |old| {
                self.allocator.free(old.value);
            }
            try self.pending_buffer_updates.put(surface_id, data_copy);
        } else {
            // Not compositing — apply immediately. Replace any existing
            // buffer; its deinit frees its own owned inline_data.
            if (surface.buffer) |*old_buf| {
                old_buf.deinit(self.allocator);
            }
            surface.buffer = .{
                .length = data_copy.len,
                .inline_data = data_copy,
            };
        }
    }

    /// Set surface visibility
    pub fn setVisible(self: *SurfaceRegistry, id: protocol.SurfaceId, visible: bool) !void {
        const surface = self.getSurface(id) orelse return error.SurfaceNotFound;
        if (surface.visible != visible) {
            surface.visible = visible;
            self.order_dirty = true; // Visibility affects composition order
        }
    }

    /// Set surface z-order
    pub fn setZOrder(self: *SurfaceRegistry, id: protocol.SurfaceId, z_order: i32) !void {
        const surface = self.getSurface(id) orelse return error.SurfaceNotFound;
        surface.z_order = z_order;
        self.order_dirty = true;
    }

    /// Set surface position
    pub fn setPosition(self: *SurfaceRegistry, id: protocol.SurfaceId, x: f32, y: f32) !void {
        const surface = self.getSurface(id) orelse return error.SurfaceNotFound;
        surface.position_x = x;
        surface.position_y = y;
    }

    /// Set surface hotspot offset, in surface-local pixels.
    /// Per ADR 0005 section 3; used by the cursor surface so that
    /// the compositor can place it at (pointer - hotspot).
    pub fn setHotspot(self: *SurfaceRegistry, id: protocol.SurfaceId, hotspot_x: i32, hotspot_y: i32) !void {
        const surface = self.getSurface(id) orelse return error.SurfaceNotFound;
        surface.hotspot_x = hotspot_x;
        surface.hotspot_y = hotspot_y;
    }

    /// Set surface logical dimensions. Used by AD-21 SET_CURSOR
    /// (sub-item 7) to update the cursor surface when a new sprite
    /// of different dimensions replaces the previous one. For
    /// ordinary surfaces, dimensions are normally set at
    /// createSurface time and not changed; this API exists for the
    /// cursor's sprite-replace path and any future use case where
    /// a surface's logical extent changes after creation.
    pub fn setLogicalSize(self: *SurfaceRegistry, id: protocol.SurfaceId, width: f32, height: f32) !void {
        const surface = self.getSurface(id) orelse return error.SurfaceNotFound;
        surface.logical_width = width;
        surface.logical_height = height;
    }

    /// Mark surface as having a pending commit
    pub fn commit(self: *SurfaceRegistry, id: protocol.SurfaceId) !u64 {
        const surface = self.getSurface(id) orelse return error.SurfaceNotFound;
        surface.pending_commit = true;
        surface.frame_number += 1;
        return surface.frame_number;
    }

    /// Get surfaces in composition order (back to front)
    pub fn getCompositionOrder(self: *SurfaceRegistry) ![]*Surface {
        if (self.order_dirty) {
            self.composition_order.clearRetainingCapacity();

            var it = self.surfaces.valueIterator();
            while (it.next()) |surface| {
                if (surface.*.visible) {
                    try self.composition_order.append(self.allocator, surface.*);
                }
            }

            // Sort by z_order (ascending = back to front)
            std.mem.sort(*Surface, self.composition_order.items, {}, struct {
                fn lessThan(_: void, a: *Surface, b: *Surface) bool {
                    return a.z_order < b.z_order;
                }
            }.lessThan);

            self.order_dirty = false;
        }

        return self.composition_order.items;
    }

    /// Get the top (highest z-order) visible client surface for input
    /// focus routing.
    ///
    /// "Client surface" excludes daemon-owned surfaces (owner =
    /// CLIENT_ID_DAEMON, e.g. the AD-21 cursor surface), which sit at
    /// reserved z-order bands above the client range and are not
    /// valid input-focus targets — they have no client to deliver
    /// events to.
    pub fn getTopVisibleSurface(self: *SurfaceRegistry) ?protocol.SurfaceId {
        const order = self.getCompositionOrder() catch return null;
        if (order.len == 0) return null;
        // Walk back-to-front (highest z-order first) and return the
        // first non-daemon-owned surface we find. The composition
        // order is sorted by z_order ascending, so the last element
        // is the top of the stack.
        var i: usize = order.len;
        while (i > 0) {
            i -= 1;
            const s = order[i];
            if (s.owner == protocol.CLIENT_ID_DAEMON) continue;
            return s.id;
        }
        return null;
    }

    /// Remove all surfaces owned by a client
    pub fn removeClientSurfaces(self: *SurfaceRegistry, client: protocol.ClientId) void {
        var to_remove = std.ArrayListUnmanaged(protocol.SurfaceId).empty;
        defer to_remove.deinit(self.allocator);

        var it = self.surfaces.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.*.owner == client) {
                to_remove.append(self.allocator, entry.key_ptr.*) catch continue;
            }
        }

        for (to_remove.items) |id| {
            self.destroySurface(id);
        }
    }

    /// Get count of surfaces
    pub fn count(self: *SurfaceRegistry) usize {
        return self.surfaces.count();
    }
};

// ============================================================================
// Tests
// ============================================================================

test "SurfaceRegistry create and destroy" {
    var registry = SurfaceRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const surface = try registry.createSurface(1, 1000, 1920, 1080);
    try std.testing.expectEqual(@as(protocol.SurfaceId, 1), surface.id);
    try std.testing.expectEqual(@as(usize, 1), registry.count());

    registry.destroySurface(surface.id);
    try std.testing.expectEqual(@as(usize, 0), registry.count());
}

test "SurfaceRegistry surface carries owner ClientId" {
    var registry = SurfaceRegistry.init(std.testing.allocator);
    defer registry.deinit();

    // AD-31.3 part 2: isOwner was removed from SurfaceRegistry
    // because per-ClientId ownership is no longer the
    // permission-check mechanism (uid is, via
    // Daemon.canModifySurface). The Surface.owner field is still
    // populated and used by the daemon for surface lifecycle
    // (disconnectClient destroys a client's surfaces), so we
    // verify the field is set correctly at creation time.
    const surface = try registry.createSurface(42, 1000, 800, 600);
    try std.testing.expectEqual(@as(protocol.ClientId, 42), surface.owner);
}

// AD-31.3: owner_uid is set at creation time, never mutates, and is
// distinct from the ClientId owner. Two surfaces from the same uid
// have the same owner_uid; two surfaces from different uids do not.
// The full enforcement story (canModifySurface, privileged bypass)
// lands in AD-31.3 part 2; this test covers the field plumbing only.
test "SurfaceRegistry surface carries owner_uid" {
    var registry = SurfaceRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const s1 = try registry.createSurface(1, 1001, 100, 100);
    const s2 = try registry.createSurface(2, 1001, 100, 100);
    const s3 = try registry.createSurface(3, 1002, 100, 100);

    try std.testing.expectEqual(@as(posix.uid_t, 1001), s1.owner_uid);
    try std.testing.expectEqual(@as(posix.uid_t, 1001), s2.owner_uid);
    try std.testing.expectEqual(@as(posix.uid_t, 1002), s3.owner_uid);

    // ClientId owners differ even when owner_uid matches.
    try std.testing.expectEqual(@as(protocol.ClientId, 1), s1.owner);
    try std.testing.expectEqual(@as(protocol.ClientId, 2), s2.owner);
}

test "SurfaceRegistry z-order sorting" {
    var registry = SurfaceRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const s1 = try registry.createSurface(1, 1000, 100, 100);
    const s2 = try registry.createSurface(1, 1000, 100, 100);
    const s3 = try registry.createSurface(1, 1000, 100, 100);

    try registry.setZOrder(s1.id, 10);
    try registry.setZOrder(s2.id, 5);
    try registry.setZOrder(s3.id, 15);

    try registry.setVisible(s1.id, true);
    try registry.setVisible(s2.id, true);
    try registry.setVisible(s3.id, true);

    const order = try registry.getCompositionOrder();
    try std.testing.expectEqual(@as(usize, 3), order.len);
    try std.testing.expectEqual(s2.id, order[0].id); // z=5
    try std.testing.expectEqual(s1.id, order[1].id); // z=10
    try std.testing.expectEqual(s3.id, order[2].id); // z=15
}

// ============================================================================
// Migration raw-fd idiom (P2 WT1): file-local close helper.
// Replaces posix.close, removed in Zig 0.16, with the raw libc call. Mirrors
// the closeFd precedent in socket_server. Duplicated per file by design
// during migration; consolidation deferred.
// ============================================================================

fn closeFd(fd: posix.fd_t) void {
    _ = posix.system.close(fd);
}
