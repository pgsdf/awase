# API overview

The Zig module exposes a small semantic API and SDCS helpers.

## App Framework

The `App` struct provides a high-level event loop abstraction for application
code. It manages the connection, surface, encoder, and frame pacing so
applications only implement drawing and input handling.

```zig
const semadraw = @import("semadraw");
const App      = semadraw.App;
const AppEvent = semadraw.AppEvent;
const Encoder  = semadraw.Encoder;

const WIDTH:  f32 = 1366;
const HEIGHT: f32 = 768;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var app = try App.init(gpa.allocator(), .{
        .title      = "My App",
        .width      = WIDTH,
        .height     = HEIGHT,
        .x          = 0,
        .y          = 0,
        .target_fps = 60,
    });
    defer app.deinit();

    var state: MyState = .{};
    try app.run(&state, onDraw, onEvent);
}

fn onDraw(ctx: *anyopaque, enc: *Encoder, frame: u64) !void {
    _ = frame;
    const s: *MyState = @ptrCast(@alignCast(ctx));
    try enc.fillRect(0, 0, WIDTH, HEIGHT, 0.0, 0.0, 0.2, 1.0);
    _ = s;
}

fn onEvent(ctx: *anyopaque, event: AppEvent) !bool {
    _ = ctx;
    return switch (event) {
        .quit        => false,
        .key   => |k| if (k.pressed) false else true,
        .mouse => |_| true,
        .frame => |_| true,
    };
}
```

### AppDesc

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `title` | `[]const u8` | `"SemaDraw App"` | Surface title |
| `width` | `f32` | `1280` | Surface width in pixels |
| `height` | `f32` | `720` | Surface height in pixels |
| `scale` | `f32` | `1.0` | Pixel scale factor |
| `z_order` | `i32` | `0` | Surface stacking order |
| `x` | `f32` | `0` | Initial X position |
| `y` | `f32` | `0` | Initial Y position |
| `socket_path` | `?[]const u8` | `null` | Socket override (null = default) |
| `target_fps` | `u32` | `60` | Frame rate target (0 = unlimited) |

### AppEvent

```zig
pub const AppEvent = union(enum) {
    quit,
    frame: struct { frame_number: u64, timestamp_ns: u64 },
    key:   struct { key_code: u32, pressed: bool, modifiers: u8 },
    mouse: struct { x: f32, y: f32, button: u8, pressed: bool, modifiers: u8 },
};
```

Return `true` from `onEvent` to continue running, `false` to quit.

### Display size

The App framework does not yet query the display size automatically. Applications
should set width and height to match the physical display. On the FreeBSD
console with the drawfs EFI framebuffer backend, the display size is reported
in `dmesg` as `VT(efifb): resolution WxH`.



The primary entry point for stream creation is `semadraw.Encoder`.

```zig
const encoder = try Encoder.init(allocator);
defer encoder.deinit();

try encoder.fillRect(x, y, w, h, color);
try encoder.strokeRect(x, y, w, h, color, stroke_width);

const sdcs_data = try encoder.finalize();
```

## IPC Protocol

Clients communicate with semadrawd via Unix domain sockets.

### Message format

All messages use an 8-byte header followed by a variable-length payload:

| Offset | Size | Field |
|--------|------|-------|
| 0 | 2 | Message type |
| 2 | 2 | Flags |
| 4 | 4 | Payload length |

All multi-byte values are little-endian.

### Message types

Reply messages use the high bit convention: replies have `0x8xxx` values, where the
low bits typically match the corresponding request (e.g., `HELLO` 0x0001 → `HELLO_REPLY` 0x8001).

#### Client → Daemon requests (0x0xxx)

| Type | Value | Description |
|------|-------|-------------|
| HELLO | 0x0001 | Client handshake |
| CREATE_SURFACE | 0x0010 | Create a new surface |
| DESTROY_SURFACE | 0x0011 | Destroy a surface |
| ATTACH_BUFFER | 0x0020 | Attach shared memory buffer |
| COMMIT | 0x0021 | Commit surface contents |
| SET_VISIBLE | 0x0030 | Set surface visibility |
| SET_Z_ORDER | 0x0031 | Set surface stacking order |
| SET_POSITION | 0x0032 | Set surface position |
| SYNC | 0x0040 | Synchronization barrier |
| CLIPBOARD_SET | 0x0050 | Set clipboard content |
| CLIPBOARD_REQUEST | 0x0051 | Request clipboard content |
| DISCONNECT | 0x00F0 | Client disconnect |

#### Daemon → Client responses (0x8xxx)

| Type | Value | Description |
|------|-------|-------------|
| HELLO_REPLY | 0x8001 | Server handshake response |
| SURFACE_CREATED | 0x8010 | Surface creation confirmed |
| SURFACE_DESTROYED | 0x8011 | Surface destruction confirmed |
| BUFFER_RELEASED | 0x8020 | Buffer can be reused |
| FRAME_COMPLETE | 0x8021 | Frame rendered notification |
| SYNC_DONE | 0x8040 | Sync barrier reached |
| ERROR_REPLY | 0x80F0 | Error response |

#### Daemon → Client events (0x9xxx)

| Type | Value | Description |
|------|-------|-------------|
| KEY_PRESS | 0x9001 | Keyboard input event |
| MOUSE_EVENT | 0x9002 | Mouse input event |
| CLIPBOARD_DATA | 0x9050 | Clipboard data response |

### Shared memory

SDCS data is passed via shared memory buffers:

1. Client creates shm region with `shm_open()`
2. Client writes SDCS data to the region
3. Client sends FD to daemon via `SCM_RIGHTS`
4. Daemon maps and validates the SDCS data
5. Daemon renders to its output

## TCP Transport (Remote Connections)

semadrawd optionally listens on a TCP port (default `7234`) for remote clients.
The TCP transport uses the same 8-byte message header and protocol as the Unix
socket, with one difference: shared memory and `SCM_RIGHTS` FD passing are not
available over the network, so SDCS data is sent inline using the
`ATTACH_BUFFER_INLINE` message type.

### Enabling the TCP transport

Pass `--tcp-port <port>` (or configure `tcp_port` in the daemon config) to
enable the listener. By default it binds to all interfaces (`0.0.0.0`); use
`--tcp-addr` to restrict to a specific address.

### Remote client IDs

Remote clients are assigned IDs starting at `0x80000000` to prevent collision
with local Unix socket client IDs, which start at `0`.

### Connection sequence (remote)

```
client                          semadrawd
  |--- TCP connect ------------>|
  |--- HELLO ------------------>|
  |<-- HELLO_REPLY (client_id) -|
  |--- CREATE_SURFACE ---------->|
  |<-- SURFACE_CREATED ----------|
  |--- ATTACH_BUFFER_INLINE ----->|  (SDCS data in message payload)
  |--- COMMIT ------------------->|
  |<-- FRAME_COMPLETE ------------|
  |--- DISCONNECT --------------->|
  |    TCP close               |
```

### Read timeout

Each accepted TCP connection has `SO_RCVTIMEO` set to 30 seconds. A client
that sends a partial message and stalls for longer than this is disconnected.
An idle client that sends no data at all is not affected — the timeout only
fires when a read is blocking mid-message.

### Inline buffer transfer

Because FD passing is unavailable, SDCS data is embedded in the message payload:

```
ATTACH_BUFFER_INLINE payload:
  surface_id   u32
  sdcs_length  u64    (bytes of SDCS data that follow)
  flags        u32    (reserved, must be 0)
  [sdcs_data]  sdcs_length bytes
```

The `RemoteConnection` client library handles this automatically via
`attachBufferInline()`.

## Backend Interface

Backends implement a vtable interface:

```zig
pub const VTable = struct {
    getCapabilities: *const fn (ctx: *anyopaque) Capabilities,
    initFramebuffer: *const fn (ctx: *anyopaque, config: FramebufferConfig) anyerror!void,
    render: *const fn (ctx: *anyopaque, request: RenderRequest) anyerror!RenderResult,
    getPixels: *const fn (ctx: *anyopaque) ?[]u8,
    resize: *const fn (ctx: *anyopaque, width: u32, height: u32) anyerror!void,
    pollEvents: *const fn (ctx: *anyopaque) bool,
    getKeyEvents: ?*const fn (ctx: *anyopaque) []const KeyEvent,
    getMouseEvents: ?*const fn (ctx: *anyopaque) []const MouseEvent,
    setClipboard: ?*const fn (ctx: *anyopaque, selection: u8, text: []const u8) anyerror!void,
    requestClipboard: ?*const fn (ctx: *anyopaque, selection: u8) void,
    getClipboardData: ?*const fn (ctx: *anyopaque, selection: u8) ?[]const u8,
    deinit: *const fn (ctx: *anyopaque) void,
};
```

Current backends:
* `software` - CPU-based reference renderer
* `headless` - No output, for testing
* `kms` - DRM/KMS direct display output (Linux/FreeBSD)
* `x11` - X11 windowed output with clipboard support
* `vulkan` - GPU-accelerated Vulkan renderer
* `wayland` - Wayland windowed output

## Client Library

The `semadraw_client` library provides a high-level API for applications.

### Connection

```zig
const client = @import("semadraw_client");

// Connect to daemon
var conn = try client.Connection.connect(allocator);
defer conn.disconnect();

// Create a surface
const surface_id = try conn.createSurface(800, 600);

// Set visibility and commit
try conn.setVisible(surface_id, true);
try conn.commit(surface_id);

// Poll for events
while (try conn.poll()) |event| {
    switch (event) {
        .frame_complete => |fc| {
            // Frame was presented
        },
        .disconnected => break,
        else => {},
    }
}
```

### Surface Wrapper

```zig
const client = @import("semadraw_client");

var conn = try client.Connection.connect(allocator);
defer conn.disconnect();

// Create surface with wrapper
var surface = try client.Surface.create(conn, 800, 600);
defer surface.destroy();

// Set frame callback for animation
surface.setFrameCallback(struct {
    fn callback(s: *client.Surface, frame: u64, ts: u64) void {
        // Render next frame
        _ = s;
        _ = frame;
        _ = ts;
    }
}.callback);

try surface.show();
try surface.commit();
```

### Surface Manager

```zig
var manager = client.SurfaceManager.init(conn);
defer manager.deinit();

var surface1 = try manager.createSurface(400, 300);
var surface2 = try manager.createSurface(400, 300);

// Process events and dispatch to surfaces
try manager.processEvents();
```

### Clipboard

The client library provides clipboard support for copy/paste operations:

```zig
const client = @import("semadraw_client");

var conn = try client.Connection.connect(allocator);
defer conn.disconnect();

// Set clipboard content (CLIPBOARD selection)
try conn.setClipboard(.clipboard, "Hello, World!");

// Set primary selection (mouse selection)
try conn.setClipboard(.primary, "Selected text");

// Request clipboard content (async)
try conn.requestClipboard(.clipboard);

// Handle clipboard data in event loop
while (try conn.poll()) |event| {
    switch (event) {
        .clipboard_data => |clip| {
            // clip.selection: .clipboard or .primary
            // clip.data: clipboard text content
            std.debug.print("Clipboard: {s}\n", .{clip.data});
        },
        else => {},
    }
}
```

Selection types:
- `.clipboard` - System clipboard (Ctrl+C/V)
- `.primary` - Primary selection (X11 mouse selection)

## Terminal Emulator (semadraw-term)

The terminal emulator demonstrates a complete SDCS client application with text rendering, input handling, and Plan 9-style mouse chording.

### Mouse State Tracking

The terminal tracks mouse button state for chord detection and selection:

```zig
const MouseState = struct {
    left_down: bool = false,
    middle_down: bool = false,
    right_down: bool = false,
    chord_handled: bool = false,  // Prevents repeat actions while held
    // Delayed selection start (preserves existing selection for chords)
    left_press_col: u32 = 0,
    left_press_row: u32 = 0,
    drag_started: bool = false,   // True once user drags past threshold
};
```

**Selection preservation**: When initiating a chord, small mouse movements are ignored (threshold: 2 cells). This prevents accidental selection reset and allows users to chord on existing selections.

### Chord Menu System

Plan 9-style chording displays context menus based on button combinations:

```zig
pub const ChordMenu = struct {
    visible: bool = false,
    menu_type: MenuType = .edit,
    x: i32 = 0,
    y: i32 = 0,
    selected: ?usize = null,

    pub const MenuType = enum {
        edit,   // Left+Middle: Copy, Clear
        paste,  // Left+Right: Paste, Paste Primary
    };

    pub fn show(self: *ChordMenu, px: i32, py: i32, mtype: MenuType) void;
    pub fn hide(self: *ChordMenu) void;
    pub fn getLabels(self: *const ChordMenu) []const []const u8;
    pub fn updateSelection(self: *ChordMenu, px: i32, py: i32) void;
};
```

Chord detection:
- **Left + Middle**: Shows Edit menu (Copy, Clear)
- **Left + Right**: Shows Paste menu (Paste, Paste Primary)
- Menu stays visible while left button is held
- Selection executes on left button release
- Immediate render triggered when menu shown to ensure visibility

### Renderer Overlay

The renderer supports menu overlays for chord menus:

```zig
pub const MenuOverlay = struct {
    x: i32,
    y: i32,
    width: u32,
    height: u32,
    item_height: u32,
    labels: []const []const u8,
    selected_idx: ?usize,
};

// Render with optional menu overlay
pub fn renderWithOverlay(self: *Self, menu: ?MenuOverlay) ![]u8;
```

The overlay is composited on top of the terminal content during rendering, allowing transient UI elements without modifying the screen buffer.

## KMS Backend Input Support

The DRM/KMS backend includes evdev input handling for keyboard and mouse when running on the console without X11/Wayland.

### Evdev Device Discovery

On initialization, the backend scans `/dev/input/event*` for input devices:

```zig
// Device types detected
const InputDeviceType = enum {
    keyboard,  // Has letter keys (KEY_Q, KEY_W, etc.)
    mouse,     // Has relative motion and BTN_LEFT
    unknown,
};
```

### Mouse Position Tracking

Since there's no window manager, the backend tracks mouse position internally:

```zig
// Mouse state maintained by backend
mouse_x: i32,  // Clamped to [0, width-1]
mouse_y: i32,  // Clamped to [0, height-1]
mouse_buttons: u8,  // Bit flags for button state
modifiers: u8,      // Shift/Alt/Ctrl/Meta state
```

### Event Queues

Events are queued during `pollEvents()` and returned via `getKeyEvents()` and `getMouseEvents()`:

- Motion events are batched (multiple REL_X/REL_Y combined into one motion event)
- Button events are emitted immediately
- Modifier key state is tracked for all events

### Permissions

The backend requires read access to `/dev/input/event*` devices. Users should be in the `input` group or run as root.
