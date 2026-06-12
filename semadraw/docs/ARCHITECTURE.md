# Architecture

SemaDraw is structured as a semantic system with strict layering.

## Client layer

Applications and toolkits link against libsemadraw.

They do not render pixels.
They construct semantic command streams describing intent.

Examples include filling a rectangle, stroking a path, drawing glyph runs, and blitting an image.

## Semantic core

The semantic core consumes SDCS streams and enforces invariants.

Responsibilities include validation of command streams, surface lifetime management, state tracking, composition, and deterministic ordering.

This layer defines behavior. It does not optimize.

## semadrawd daemon

The daemon is the central authority for surface management and composition.

### IPC layer
* Unix domain socket at `/var/run/semadraw/semadraw.sock`
* Binary message protocol with 8-byte headers
* FD passing for shared memory buffers (local connections)

### Remote transport
* TCP server for network connections (optional, port 7234 default)
* Same binary protocol as local connections
* Inline buffer transfer for SDCS data (no FD passing over network)
* Remote clients identified by high client IDs (0x80000000+)

### Client sessions
* Per-client resource tracking and limits
* Surface ownership enforcement
* Automatic cleanup on disconnect

#### Disconnect lifecycle

The poll loop reads from a client fd in a single `revents` decode.
`POLL.IN` and `POLL.HUP` can land in the same revents — the kernel
delivers both when a client closes its end of the socket with
readable data still pending.

The IN branch may run `disconnectClient`, which destroys the
session and frees `ClientSession.sdcs_buffer`. The HUP branch must
not then dereference the session pointer. The poll loop captures
`session.id` into a local `sid` and tracks a `disconnected` flag so
the second branch is skipped if the first already cleaned up. Same
shape applies to remote clients via `disconnectRemoteClient`.

#### Surface buffer ownership

`SurfaceRegistry.attachInlineBuffer` always copies the caller's
data. The surface owns the copy; `AttachedBuffer.deinit(allocator)`
frees `inline_data` when non-null.

The two callers in `semadrawd.zig` pass `session.sdcs_buffer.?`,
which the session frees on disconnect. Borrowing rather than
copying would dangle the surface's pointer at the SDCS header
offset and segfault on the next composite. Both the immediate (not
compositing) and deferred (compositing) paths converge on the same
ownership story.

### Surface registry
* Unique surface IDs across all clients
* Z-order management for composition
* Visibility and position tracking

### Compositor
* Damage tracking with region accumulation
* Frame scheduling with vsync alignment
* Adaptive refresh rate based on performance

### Backend abstraction
* Vtable-based interface for backend implementations
* Process isolation via fork for untrusted backends
* Software renderer as reference implementation

## Backend layer

Backends translate semantic intent into execution.

Examples include a reference software renderer, a Vulkan accelerated renderer, a DRM KMS presentation backend, and host bridges such as X11 or Wayland.

Backends must not alter semantics.
They are interchangeable implementations.

### Software backend

The reference implementation renders to a memory buffer using CPU rasterization.
Supports anti-aliasing, all blend modes, and deterministic output.
Used for golden image testing and headless rendering.

Performance optimizations:
* SIMD vectorization (SSE2/AVX on x86, NEON on ARM)
* 4-pixel parallel blending operations
* Vectorized 4x4 sub-pixel AA sampling
* Interior/edge separation for rectangle fills

### DRM/KMS backend

Direct display output without a window system.
Uses kernel mode setting for display configuration:
* Automatic device enumeration (`/dev/dri/card0`, etc.)
* Connector and CRTC discovery
* Mode setting with preferred resolution
* Double-buffered dumb buffers
* Page flipping with VSync

Suitable for:
* Dedicated display systems (kiosks, embedded)
* FreeBSD console graphics
* Testing without X11/Wayland

### X11 backend

Windowed output for X11 desktop environments.
Uses Xlib for window management:
* XImage for framebuffer display
* Window resize handling
* Keyboard and close event handling
* BGRA pixel format for X11 compatibility

Suitable for:
* Development and testing
* Desktop integration
* Existing X11 environments

### Vulkan backend

GPU-accelerated rendering with Vulkan API.
Uses X11 surface for presentation:
* Vulkan instance with VK_KHR_xlib_surface extension
* Physical device selection (prefers discrete GPUs)
* Swapchain with mailbox present mode (low latency)
* Command buffer recording and submission
* Fence and semaphore synchronization
* Keyboard and window close event handling

Suitable for:
* High-performance rendering
* GPU-accelerated compositing
* Systems with Vulkan-capable GPUs

### Wayland backend

Windowed output for Wayland desktop environments.
Uses libwayland-client with XDG shell:
* wl_shm shared memory buffers
* XDG toplevel window management
* Keyboard event handling with xkb modifiers
* Window resize and close events
* ARGB8888 pixel format

Suitable for:
* Modern Linux desktops (GNOME, KDE, Sway)
* Wayland-native environments
* Development and testing without X11

## Applications

### semadraw-term

VT100-compatible terminal emulator for SemaDraw console environments.

Architecture:
* `font.zig` - 8x16 VGA bitmap font with atlas generation
* `screen.zig` - Unicode cell buffer with width tracking (CJK double-width)
* `vt100.zig` - ANSI/VT100 escape sequence parser with UTF-8 decoding
* `pty.zig` - Linux PTY handling for shell communication
* `renderer.zig` - Converts screen buffer to SDCS glyph runs

Data flow:
1. PTY receives shell output (raw bytes)
2. VT100 parser decodes UTF-8 and processes escape sequences
3. Screen buffer updated with Unicode codepoints and attributes
4. Renderer batches cells by color into glyph runs
5. SDCS data sent to daemon via client library

UTF-8 support:
* Full multi-byte decoding (2/3/4 byte sequences)
* Wide character support (CJK takes 2 columns)
* Zero-width character handling (combining marks)
* Fallback glyph for characters not in VGA font

## Key property

No backend specific concept appears in the public API.
