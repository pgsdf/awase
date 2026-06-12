# Roadmap

This roadmap tracks the incremental execution order used by the golden test suite.
Each feature is implemented end to end (encoder, SDCS, replay, tests, docs) before moving on.

## Completed

* Core container format (SDCS v1) and validator
* Replay tool (software backend) and golden test harness
* Transform 2D
* Clip rects v1
* Blend modes v1 (Src, SrcOver, Multiply, Screen)
* Stroke rect v1 (axis aligned)
* Stroke line v1
* Joins v1 (miter, bevel)
* Caps v1 (butt, square)
* Caps v2 (round)
* Joins v2 (round join)
* Code style cleanup (encoder.zig indentation, struct organization)
* Enhanced validation diagnostics (opcodeName, ValidationDiagnostics, validateFileWithDiagnostics)
* Unit tests for core validation logic (sdcs.zig)
* Malformed input test suite (sdcs_test_malformed)
* Fuzzing harness (sdcs_fuzz with AFL/libFuzzer support)
* Determinism verification in test suite
* Miter limit (SET_MITER_LIMIT opcode, miter-to-bevel fallback for 90° joins)
* Stroke line v2 (non-axis-aligned lines with proper rasterization)
* BLIT_IMAGE implementation (encoder, replay, tests)
* Curves v1 (quadratic and cubic Bezier strokes)
* Stroke path v1 (polyline with arbitrary segments)
* DRAW_GLYPH_RUN / Text v1 (simple glyph atlas)
* Deterministic anti-aliasing (SET_ANTIALIAS opcode, 4x4 sub-pixel coverage sampling)
* AA test suite (sdcs_make_aa test generator with golden hash verification)

### semadrawd daemon
* IPC protocol (Unix domain socket with message framing)
* Client session management with resource limits
* Surface registry (creation, ownership, z-ordering)
* Shared memory buffer attachment
* SDCS validation before execution
* Backend abstraction layer (vtable-based interface)
* Software renderer backend
* Process isolation for backends (fork-based)
* Compositor with damage tracking
* Frame scheduler with vsync timing
* Client library (Connection and Surface wrappers)
* DRM/KMS presentation backend (direct framebuffer output)
* SIMD vectorization for rasterization (SSE/AVX, NEON)
* X11 backend for windowed display
* Vulkan backend (GPU-accelerated rendering with X11 presentation)
* Remote transport (TCP server, inline buffer transfer, remote client library)
* Wayland backend for windowed display (keyboard and mouse input support)

### Applications
* Terminal emulator (semadraw-term) for console environment

## Next

### semadraw-term Improvements

#### Critical (Blocks Basic Functionality)
* ~~Connect keyboard input handling~~ (DONE - full pipeline from X11 backend through daemon to terminal)
* ~~Alternative screen buffer support~~ (DONE - modes 47/1047/1049 for vim, htop, less, nano)
* ~~Missing VT100 escape sequences~~ (DONE - RIS, IND, NEL, RI, DECSC/DECRC, cursor visibility mode 25)

#### High Priority (Major Features)
* ~~Scrollback buffer~~ (DONE - ring buffer with Shift+PageUp/Down navigation)
* ~~Fix double encoder reset bug in renderer.zig~~ (DONE - removed duplicate reset call)
* ~~Extended character support~~ (DONE - added box drawing U+2500-U+257F, full block, improved fallback glyph)
* ~~OSC escape sequence processing~~ (DONE - OSC 0/1/2 for title, OSC 4/10/11 for colors, OSC 104/110/111 for reset)

#### Medium Priority (Enhancements)
* ~~Mouse input support~~ (DONE - X10/VT200/SGR mouse tracking modes 9/1000-1006/1015, button/motion events)
* ~~Additional SGR codes~~ (DONE - strikethrough SGR 9/29, overline SGR 53/55, double underline SGR 21)
* ~~Cursor style variations~~ (DONE - block/underline/bar styles via DECSCUSR CSI Ps SP q, 500ms blink animation)
* ~~Dirty region tracking~~ (DONE - per-row dirty flags, renderer skips unchanged rows)

#### Performance Optimizations
* ~~Compile-time or cached font atlas generation~~ (DONE - Font.ATLAS comptime constant, Renderer uses pointer)
* ~~Reuse glyph ArrayList instead of allocating per row~~ (DONE - single reusable glyph_buffer in Renderer)
* ~~Cell caching for glyph index lookups~~ (DONE - glyph_idx field cached in Cell, computed on character write)
* ~~Optimize screen scrolling with block operations~~ (DONE - @memset/@memcpy for scroll, erase, insert/delete)

#### Code Quality
* ~~Remove or connect dead handleKeyPress code~~ (DONE - handleKeyPress connected to key_press events in main loop)
* ~~Replace magic numbers with named constants~~ (DONE - Key, Modifiers, Ascii structs for evdev codes and control chars)
* ~~Add logging for silently dropped events~~ (DONE - debug logs for unhandled keys, CSI, DECSET/DECRST, SGR, control chars)
* ~~Terminal state validation improvements~~ (DONE - validateState/assertValid for cursor, scroll region, scrollback invariants)

## Backend Feature Parity

Current implementation status for input and clipboard across backends:

| Feature           | X11 | Wayland | KMS/DRM | Vulkan | Vulkan Console | Software |
|-------------------|-----|---------|---------|--------|----------------|----------|
| Keyboard Input    | ✓   | ✓       | ✓       | ✓      | ✓              | N/A      |
| Mouse Input       | ✓   | ✓       | ✓       | ✓      | ✓              | N/A      |
| Clipboard Set     | ✓   | ✓**     | ✓*      | ✓      | ✓*             | N/A      |
| Clipboard Get     | ✓   | ✓**     | ✓*      | ✓      | ✓*             | N/A      |
| Clipboard Pending | ✓   | ✓**     | ✓*      | ✓      | ✓*             | N/A      |

Notes:
- Software backend is headless (no display) - input not applicable
- Vulkan uses X11 window for presentation with full X11 input/clipboard support
- Vulkan Console uses VK_KHR_display for direct display output
  - Linux: evdev for input (/dev/input/event*)
  - FreeBSD: sysmouse + console keyboard (/dev/sysmouse, /dev/kbdmux0)
- KMS/DRM and Vulkan Console use file-based clipboard (/tmp/.semadraw-clipboard, /tmp/.semadraw-primary)
  - *Works within semadraw sessions, not shared with other applications
- **Wayland clipboard uses wl_data_device protocol (CLIPBOARD only, no PRIMARY selection)
  - PRIMARY selection requires zwp_primary_selection_device_manager_v1 extension

### Recently Completed

* **Vulkan Console Backend** ✓
  - GPU-accelerated rendering directly to DRM/KMS (no X11/Wayland)
  - Uses VK_KHR_display extension for direct display output
  - Cross-platform input: evdev on Linux, sysmouse/kbdmux on FreeBSD
  - Provides GPU acceleration for console/TTY environments

* **Input Abstraction Layer** ✓
  - Factored evdev handling into reusable module (src/backend/evdev.zig)
  - Added BSD input module (src/backend/bsdinput.zig) for FreeBSD support
  - KMS backend uses evdev module
  - Vulkan console backend auto-selects evdev (Linux) or bsdinput (FreeBSD)

