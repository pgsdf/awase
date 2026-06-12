//! SemaDraw Client Library
//!
//! High-level API for connecting to semadrawd and managing surfaces.
//!
//! ## Usage
//!
//! ```zig
//! const client = @import("semadraw_client");
//!
//! // Connect to daemon
//! var conn = try client.Connection.connect(allocator);
//! defer conn.disconnect();
//!
//! // Create a surface
//! var surface = try client.Surface.create(conn, 800, 600);
//! defer surface.destroy();
//!
//! // Show and commit
//! try surface.show();
//! try surface.commit();
//! ```

pub const Connection = @import("connection").Connection;
pub const ConnectionState = @import("connection").ConnectionState;
pub const Event = @import("connection").Event;
pub const ParsedGesture = @import("connection").ParsedGesture;
pub const GesturePayload = @import("connection").GesturePayload;

pub const RemoteConnection = @import("remote_connection").RemoteConnection;

pub const Surface = @import("surface").Surface;
pub const SurfaceState = @import("surface").SurfaceState;
pub const SurfaceManager = @import("surface").SurfaceManager;
pub const FrameCallback = @import("surface").FrameCallback;

pub const protocol = @import("protocol");

/// Connect to the daemon using default settings (local Unix socket)
pub fn connect(allocator: std.mem.Allocator) !*Connection {
    return Connection.connect(allocator);
}

/// Connect to the daemon at a specific socket path (local)
pub fn connectTo(allocator: std.mem.Allocator, socket_path: []const u8) !*Connection {
    return Connection.connectTo(allocator, socket_path);
}

/// Connect to a remote daemon over TCP
pub fn connectRemote(allocator: std.mem.Allocator, host: []const u8, port: u16) !*RemoteConnection {
    return RemoteConnection.connect(allocator, host, port);
}

/// Connect to a remote daemon using default port
pub fn connectRemoteDefault(allocator: std.mem.Allocator, host: []const u8) !*RemoteConnection {
    return RemoteConnection.connectDefault(allocator, host);
}

const std = @import("std");

test {
    _ = @import("connection");
    _ = @import("remote_connection");
    _ = @import("surface");
}
