const std = @import("std");

pub fn build(b: *std.Build) void {
    const target   = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // -----------------------------------------------------------------------
    // Backend feature flags
    //
    // Each GPU-dependent backend can be disabled at build time for
    // environments where the required libraries are absent (e.g. VirtualBox,
    // CI, headless servers).  The software and drawfs backends are always
    // included and require no external libraries.
    //
    // Usage:
    //   zig build                          # all backends (default)
    //   zig build -Dconsole=true           # no X11/Wayland (bare console)
    //   zig build -Dx11=false              # disable X11
    //   zig build -Dvulkan=false           # disable Vulkan
    //   zig build -Dwayland=false          # disable Wayland
    //   zig build -Dbsdinput=false         # disable libinput/libudev
    //   zig build -Dgpu=false              # disable all GPU backends at once
    //   zig build -Dconsole=true           # console mode: no X11/Wayland
    //   zig build -Dconsole=true           # console mode: no X11/Wayland
    // -----------------------------------------------------------------------
    // Each GPU backend defaults to FALSE — opt in explicitly.
    // On bare metal with all libraries present: zig build -Dgpu=true
    // On VirtualBox or console without GPU libs: zig build  (uses software/drawfs only)
    const want_gpu     = b.option(bool, "gpu",     "Enable all GPU-dependent backends (default: false)") orelse false;
    const want_x11     = b.option(bool, "x11",     "Enable X11 backend (requires libX11)")              orelse want_gpu;
    const want_vulkan  = b.option(bool, "vulkan",  "Enable Vulkan backends (requires libvulkan)")       orelse want_gpu;
    const want_wayland = b.option(bool, "wayland", "Enable Wayland backend (requires libwayland-client)") orelse want_gpu;
    const want_bsdinput = b.option(bool, "bsdinput", "Enable bsdinput/libinput/libudev")                orelse want_gpu;

    const semadraw_root = b.path("src/semadraw.zig");
    const sdcs_root     = b.path("src/sdcs.zig");

    // Zig 0.15+ build API uses explicit root modules.
    const semadraw_mod = b.createModule(.{
        .root_source_file = semadraw_root,
        .target = target,
        .optimize = optimize,
    });
    const sdcs_mod = b.createModule(.{
        .root_source_file = sdcs_root,
        .target = target,
        .optimize = optimize,
    });

    // SIMD acceleration module
    const simd_mod = b.createModule(.{
        .root_source_file = b.path("src/simd.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Static library
    const lib = b.addLibrary(.{
        .name = "semadraw",
        .root_module = semadraw_mod,
        .linkage = .static,
    });
    b.installArtifact(lib);

    // Tools
    const sdcs_dump = b.addExecutable(.{
        .name = "sdcs_dump",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tools/sdcs_dump.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    sdcs_dump.root_module.addImport("semadraw", semadraw_mod);
    sdcs_dump.root_module.addImport("sdcs", sdcs_mod);
    b.installArtifact(sdcs_dump);

    const sdcs_make_test = b.addExecutable(.{
        .name = "sdcs_make_test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tools/sdcs_make_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    sdcs_make_test.root_module.addImport("semadraw", semadraw_mod);
    sdcs_make_test.root_module.addImport("sdcs", sdcs_mod);
    b.installArtifact(sdcs_make_test);

    const sdcs_make_overlap = b.addExecutable(.{
        .name = "sdcs_make_overlap",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tools/sdcs_make_overlap.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    sdcs_make_overlap.root_module.addImport("semadraw", semadraw_mod);
    sdcs_make_overlap.root_module.addImport("sdcs", sdcs_mod);
    b.installArtifact(sdcs_make_overlap);

    const sdcs_make_fractional = b.addExecutable(.{
        .name = "sdcs_make_fractional",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tools/sdcs_make_fractional.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    sdcs_make_fractional.root_module.addImport("semadraw", semadraw_mod);
    sdcs_make_fractional.root_module.addImport("sdcs", sdcs_mod);
    b.installArtifact(sdcs_make_fractional);

    const sdcs_make_clip = b.addExecutable(.{
        .name = "sdcs_make_clip",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tools/sdcs_make_clip.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    sdcs_make_clip.root_module.addImport("semadraw", semadraw_mod);
    sdcs_make_clip.root_module.addImport("sdcs", sdcs_mod);
    b.installArtifact(sdcs_make_clip);

    const sdcs_make_transform = b.addExecutable(.{
        .name = "sdcs_make_transform",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tools/sdcs_make_transform.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    sdcs_make_transform.root_module.addImport("semadraw", semadraw_mod);
    sdcs_make_transform.root_module.addImport("sdcs", sdcs_mod);
    b.installArtifact(sdcs_make_transform);

    const sdcs_make_blend = b.addExecutable(.{
        .name = "sdcs_make_blend",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tools/sdcs_make_blend.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    sdcs_make_blend.root_module.addImport("semadraw", semadraw_mod);
    sdcs_make_blend.root_module.addImport("sdcs", sdcs_mod);
    b.installArtifact(sdcs_make_blend);
	const sdcs_make_stroke = b.addExecutable(.{
	    .name = "sdcs_make_stroke",
	    .root_module = b.createModule(.{
	        .root_source_file = b.path("src/tools/sdcs_make_stroke.zig"),
	        .target = target,
	        .optimize = optimize,
	    }),
	});
	sdcs_make_stroke.root_module.addImport("semadraw", semadraw_mod);
	sdcs_make_stroke.root_module.addImport("sdcs", sdcs_mod);
	b.installArtifact(sdcs_make_stroke);

	const sdcs_make_line = b.addExecutable(.{
	    .name = "sdcs_make_line",
	    .root_module = b.createModule(.{
	        .root_source_file = b.path("src/tools/sdcs_make_line.zig"),
	        .target = target,
	        .optimize = optimize,
	    }),
	});
	sdcs_make_line.root_module.addImport("semadraw", semadraw_mod);
	sdcs_make_line.root_module.addImport("sdcs", sdcs_mod);
	b.installArtifact(sdcs_make_line);

	const sdcs_make_join = b.addExecutable(.{
	    .name = "sdcs_make_join",
	    .root_module = b.createModule(.{
	        .root_source_file = b.path("src/tools/sdcs_make_join.zig"),
	        .target = target,
	        .optimize = optimize,
	    }),
	});
	sdcs_make_join.root_module.addImport("semadraw", semadraw_mod);
	sdcs_make_join.root_module.addImport("sdcs", sdcs_mod);
	b.installArtifact(sdcs_make_join);

	const sdcs_make_join_round = b.addExecutable(.{
	    .name = "sdcs_make_join_round",
	    .root_module = b.createModule(.{
	        .root_source_file = b.path("src/tools/sdcs_make_join_round.zig"),
	        .target = target,
	        .optimize = optimize,
	    }),
	});
	sdcs_make_join_round.root_module.addImport("semadraw", semadraw_mod);
	sdcs_make_join_round.root_module.addImport("sdcs", sdcs_mod);
	b.installArtifact(sdcs_make_join_round);

	const sdcs_make_cap = b.addExecutable(.{
	    .name = "sdcs_make_cap",
	    .root_module = b.createModule(.{
	        .root_source_file = b.path("src/tools/sdcs_make_cap.zig"),
	        .target = target,
	        .optimize = optimize,
	    }),
	});
	sdcs_make_cap.root_module.addImport("semadraw", semadraw_mod);
	sdcs_make_cap.root_module.addImport("sdcs", sdcs_mod);
	b.installArtifact(sdcs_make_cap);

	const sdcs_make_cap_round = b.addExecutable(.{
	    .name = "sdcs_make_cap_round",
	    .root_module = b.createModule(.{
	        .root_source_file = b.path("src/tools/sdcs_make_cap_round.zig"),
	        .target = target,
	        .optimize = optimize,
	    }),
	});
	sdcs_make_cap_round.root_module.addImport("semadraw", semadraw_mod);
	sdcs_make_cap_round.root_module.addImport("sdcs", sdcs_mod);
	b.installArtifact(sdcs_make_cap_round);

	const sdcs_make_miter_limit = b.addExecutable(.{
	    .name = "sdcs_make_miter_limit",
	    .root_module = b.createModule(.{
	        .root_source_file = b.path("src/tools/sdcs_make_miter_limit.zig"),
	        .target = target,
	        .optimize = optimize,
	    }),
	});
	sdcs_make_miter_limit.root_module.addImport("semadraw", semadraw_mod);
	sdcs_make_miter_limit.root_module.addImport("sdcs", sdcs_mod);
	b.installArtifact(sdcs_make_miter_limit);

	const sdcs_make_diagonal = b.addExecutable(.{
	    .name = "sdcs_make_diagonal",
	    .root_module = b.createModule(.{
	        .root_source_file = b.path("src/tools/sdcs_make_diagonal.zig"),
	        .target = target,
	        .optimize = optimize,
	    }),
	});
	sdcs_make_diagonal.root_module.addImport("semadraw", semadraw_mod);
	sdcs_make_diagonal.root_module.addImport("sdcs", sdcs_mod);
	b.installArtifact(sdcs_make_diagonal);

	const sdcs_make_blit = b.addExecutable(.{
	    .name = "sdcs_make_blit",
	    .root_module = b.createModule(.{
	        .root_source_file = b.path("src/tools/sdcs_make_blit.zig"),
	        .target = target,
	        .optimize = optimize,
	    }),
	});
	sdcs_make_blit.root_module.addImport("semadraw", semadraw_mod);
	sdcs_make_blit.root_module.addImport("sdcs", sdcs_mod);
	b.installArtifact(sdcs_make_blit);

	const sdcs_make_curves = b.addExecutable(.{
	    .name = "sdcs_make_curves",
	    .root_module = b.createModule(.{
	        .root_source_file = b.path("src/tools/sdcs_make_curves.zig"),
	        .target = target,
	        .optimize = optimize,
	    }),
	});
	sdcs_make_curves.root_module.addImport("semadraw", semadraw_mod);
	sdcs_make_curves.root_module.addImport("sdcs", sdcs_mod);
	b.installArtifact(sdcs_make_curves);

	const sdcs_make_path = b.addExecutable(.{
	    .name = "sdcs_make_path",
	    .root_module = b.createModule(.{
	        .root_source_file = b.path("src/tools/sdcs_make_path.zig"),
	        .target = target,
	        .optimize = optimize,
	    }),
	});
	sdcs_make_path.root_module.addImport("semadraw", semadraw_mod);
	sdcs_make_path.root_module.addImport("sdcs", sdcs_mod);
	b.installArtifact(sdcs_make_path);

	const sdcs_make_text = b.addExecutable(.{
	    .name = "sdcs_make_text",
	    .root_module = b.createModule(.{
	        .root_source_file = b.path("src/tools/sdcs_make_text.zig"),
	        .target = target,
	        .optimize = optimize,
	    }),
	});
	sdcs_make_text.root_module.addImport("semadraw", semadraw_mod);
	sdcs_make_text.root_module.addImport("sdcs", sdcs_mod);
	b.installArtifact(sdcs_make_text);

	const sdcs_make_glyph = b.addExecutable(.{
	    .name = "sdcs_make_glyph",
	    .root_module = b.createModule(.{
	        .root_source_file = b.path("src/tools/sdcs_make_glyph.zig"),
	        .target = target,
	        .optimize = optimize,
	    }),
	});
	sdcs_make_glyph.root_module.addImport("semadraw", semadraw_mod);
	sdcs_make_glyph.root_module.addImport("sdcs", sdcs_mod);
	b.installArtifact(sdcs_make_glyph);

	const sdcs_make_aa = b.addExecutable(.{
	    .name = "sdcs_make_aa",
	    .root_module = b.createModule(.{
	        .root_source_file = b.path("src/tools/sdcs_make_aa.zig"),
	        .target = target,
	        .optimize = optimize,
	    }),
	});
	sdcs_make_aa.root_module.addImport("semadraw", semadraw_mod);
	b.installArtifact(sdcs_make_aa);

	const sdcs_make_demo = b.addExecutable(.{
	    .name = "sdcs_make_demo",
	    .root_module = b.createModule(.{
	        .root_source_file = b.path("src/tools/sdcs_make_demo.zig"),
	        .target = target,
	        .optimize = optimize,
	    }),
	});
	sdcs_make_demo.root_module.addImport("semadraw", semadraw_mod);
	b.installArtifact(sdcs_make_demo);

    const sdcs_replay = b.addExecutable(.{
        .name = "sdcs_replay",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tools/sdcs_replay.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    sdcs_replay.root_module.addImport("semadraw", semadraw_mod);
    sdcs_replay.root_module.addImport("sdcs", sdcs_mod);
    sdcs_replay.root_module.addImport("simd", simd_mod);
    b.installArtifact(sdcs_replay);

    // Test tool for malformed inputs
    const sdcs_test_malformed = b.addExecutable(.{
        .name = "sdcs_test_malformed",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tools/sdcs_test_malformed.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    sdcs_test_malformed.root_module.addImport("semadraw", semadraw_mod);
    sdcs_test_malformed.root_module.addImport("sdcs", sdcs_mod);
    b.installArtifact(sdcs_test_malformed);

    // Fuzzing harness
    const sdcs_fuzz = b.addExecutable(.{
        .name = "sdcs_fuzz",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tools/sdcs_fuzz.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    sdcs_fuzz.root_module.addImport("semadraw", semadraw_mod);
    sdcs_fuzz.root_module.addImport("sdcs", sdcs_mod);
    b.installArtifact(sdcs_fuzz);

    // IPC protocol module (for semadrawd and clients)
    const ipc_protocol_mod = b.createModule(.{
        .root_source_file = b.path("src/ipc/protocol.zig"),
        .target = target,
        .optimize = optimize,
    });

    // shared/src/session.zig — session identity for unified event log.
    const session_mod = b.createModule(.{
        .root_source_file = b.path("../shared/src/session.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Daemon event emitter module.
    const events_mod = b.createModule(.{
        .root_source_file = b.path("src/daemon/events.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "session", .module = session_mod },
        },
    });

    const ipc_socket_mod = b.createModule(.{
        .root_source_file = b.path("src/ipc/socket_server.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "protocol", .module = ipc_protocol_mod },
        },
    });

    const ipc_tcp_mod = b.createModule(.{
        .root_source_file = b.path("src/ipc/tcp_server.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "protocol", .module = ipc_protocol_mod },
        },
    });

    const ipc_shm_mod = b.createModule(.{
        .root_source_file = b.path("src/ipc/shm.zig"),
        .target = target,
        .optimize = optimize,
    });

    const client_session_mod = b.createModule(.{
        .root_source_file = b.path("src/daemon/client_session.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "protocol", .module = ipc_protocol_mod },
            .{ .name = "socket_server", .module = ipc_socket_mod },
        },
    });

    const surface_registry_mod = b.createModule(.{
        .root_source_file = b.path("src/daemon/surface_registry.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "protocol", .module = ipc_protocol_mod },
        },
    });

    const sdcs_validator_mod = b.createModule(.{
        .root_source_file = b.path("src/daemon/sdcs_validator.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "sdcs", .module = sdcs_mod },
        },
    });

    // Backend modules
    const backend_mod = b.createModule(.{
        .root_source_file = b.path("src/backend/backend.zig"),
        .target = target,
        .optimize = optimize,
    });

    const software_backend_mod = b.createModule(.{
        .root_source_file = b.path("src/backend/software.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "backend", .module = backend_mod },
        },
    });

    // Add software import to backend module for createBackend
    backend_mod.addImport("software", software_backend_mod);

    // Evdev input module (shared by DRM and future Vulkan console backends)
    const evdev_mod = b.createModule(.{
        .root_source_file = b.path("src/backend/evdev.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "backend", .module = backend_mod },
        },
    });

    const drm_backend_mod = b.createModule(.{
        .root_source_file = b.path("src/backend/drm.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "backend", .module = backend_mod },
            .{ .name = "evdev", .module = evdev_mod },
        },
    });

    // Add drm import to backend module for createBackend
    backend_mod.addImport("drm", drm_backend_mod);

    // X11 backend module
    const x11_backend_mod = b.createModule(.{
        .root_source_file = b.path(if (want_x11) "src/backend/x11.zig" else "src/backend/stub_x11.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "backend", .module = backend_mod },
        },
    });
    if (want_x11) {
        x11_backend_mod.link_libc = true;
        x11_backend_mod.linkSystemLibrary("X11", .{});
    }

    // Add x11 import to backend module for createBackend
    backend_mod.addImport("x11", x11_backend_mod);

    // Vulkan backend module
    const vulkan_backend_mod = b.createModule(.{
        .root_source_file = b.path(if (want_vulkan) "src/backend/vulkan.zig" else "src/backend/stub_vulkan.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "backend", .module = backend_mod },
        },
    });
    if (want_vulkan) {
        vulkan_backend_mod.link_libc = true;
        vulkan_backend_mod.linkSystemLibrary("vulkan", .{});
        vulkan_backend_mod.linkSystemLibrary("X11", .{});
    }

    // Add vulkan import to backend module for createBackend
    backend_mod.addImport("vulkan", vulkan_backend_mod);

    // Wayland backend module
    const wayland_backend_mod = b.createModule(.{
        .root_source_file = b.path(if (want_wayland) "src/backend/wayland.zig" else "src/backend/stub_wayland.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "backend", .module = backend_mod },
        },
    });
    if (want_wayland) {
        wayland_backend_mod.link_libc = true;
        wayland_backend_mod.linkSystemLibrary("wayland-client", .{});
    }

    // Add wayland import to backend module for createBackend
    backend_mod.addImport("wayland", wayland_backend_mod);

    // BSD input module (for FreeBSD/OpenBSD/NetBSD console input)
    const bsdinput_mod = b.createModule(.{
        .root_source_file = b.path(if (want_bsdinput) "src/backend/bsdinput.zig" else "src/backend/stub_bsdinput.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "backend", .module = backend_mod },
        },
    });
    if (want_bsdinput) {
        bsdinput_mod.link_libc = true;
        bsdinput_mod.linkSystemLibrary("input", .{});
        bsdinput_mod.linkSystemLibrary("udev", .{});
    }

    // Vulkan console backend module (VK_KHR_display for direct display output)
    const vulkan_console_backend_mod = b.createModule(.{
        .root_source_file = b.path(if (want_vulkan) "src/backend/vulkan_console.zig" else "src/backend/stub_vulkan_console.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "backend", .module = backend_mod },
            .{ .name = "evdev", .module = evdev_mod },
            .{ .name = "bsdinput", .module = bsdinput_mod },
        },
    });
    if (want_vulkan) {
        vulkan_console_backend_mod.link_libc = true;
        vulkan_console_backend_mod.linkSystemLibrary("vulkan", .{});
    }

    // Add vulkan_console import to backend module for createBackend
    backend_mod.addImport("vulkan_console", vulkan_console_backend_mod);

    // drawfs backend module (FreeBSD drawfs kernel module)
    const drawfs_backend_mod = b.createModule(.{
        .root_source_file = b.path("src/backend/drawfs.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "backend", .module = backend_mod },
            .{ .name = "bsdinput", .module = bsdinput_mod },
        },
    });
    drawfs_backend_mod.link_libc = true;

    // Add drawfs import to backend module for createBackend
    backend_mod.addImport("drawfs", drawfs_backend_mod);

    const backend_process_mod = b.createModule(.{
        .root_source_file = b.path("src/backend/process.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "backend", .module = backend_mod },
        },
    });

    // Compositor modules
    const damage_mod = b.createModule(.{
        .root_source_file = b.path("src/compositor/damage.zig"),
        .target = target,
        .optimize = optimize,
    });

    // shared/src/clock.zig — audio hardware clock reader for C-4.
    const shared_clock_mod = b.createModule(.{
        .root_source_file = b.path("../shared/src/clock.zig"),
        .target = target,
        .optimize = optimize,
    });

    const frame_scheduler_mod = b.createModule(.{
        .root_source_file = b.path("src/compositor/frame_scheduler.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "shared_clock", .module = shared_clock_mod },
        },
    });

    const compositor_mod = b.createModule(.{
        .root_source_file = b.path("src/compositor/compositor.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "damage", .module = damage_mod },
            .{ .name = "frame_scheduler", .module = frame_scheduler_mod },
            .{ .name = "backend", .module = backend_mod },
            .{ .name = "surface_registry", .module = surface_registry_mod },
            .{ .name = "shared_clock", .module = shared_clock_mod },
        },
    });

    // semadrawd daemon
    const semadrawd = b.addExecutable(.{
        .name = "semadrawd",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/daemon/semadrawd.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "protocol", .module = ipc_protocol_mod },
                .{ .name = "socket_server", .module = ipc_socket_mod },
                .{ .name = "tcp_server", .module = ipc_tcp_mod },
                .{ .name = "client_session", .module = client_session_mod },
                .{ .name = "surface_registry", .module = surface_registry_mod },
                .{ .name = "shm", .module = ipc_shm_mod },
                .{ .name = "sdcs_validator", .module = sdcs_validator_mod },
                .{ .name = "backend", .module = backend_mod },
                .{ .name = "backend_process", .module = backend_process_mod },
                .{ .name = "compositor", .module = compositor_mod },
                .{ .name = "events", .module = events_mod },
            },
        }),
    });
    b.installArtifact(semadrawd);

    // Client library modules
    const client_connection_mod = b.createModule(.{
        .root_source_file = b.path("src/client/connection.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "protocol", .module = ipc_protocol_mod },
        },
    });

    const client_remote_mod = b.createModule(.{
        .root_source_file = b.path("src/client/remote_connection.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "protocol", .module = ipc_protocol_mod },
        },
    });

    const client_surface_mod = b.createModule(.{
        .root_source_file = b.path("src/client/surface.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "protocol", .module = ipc_protocol_mod },
            .{ .name = "connection", .module = client_connection_mod },
        },
    });

    const client_mod = b.createModule(.{
        .root_source_file = b.path("src/client/client.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "protocol", .module = ipc_protocol_mod },
            .{ .name = "connection", .module = client_connection_mod },
            .{ .name = "remote_connection", .module = client_remote_mod },
            .{ .name = "surface", .module = client_surface_mod },
        },
    });

    // Client library (static)
    const client_lib = b.addLibrary(.{
        .name = "semadraw_client",
        .root_module = client_mod,
        .linkage = .static,
    });
    b.installArtifact(client_lib);

    // Terminal emulator modules
    const term_font_mod = b.createModule(.{
        .root_source_file = b.path("src/apps/term/font.zig"),
        .target = target,
        .optimize = optimize,
    });

    const term_screen_mod = b.createModule(.{
        .root_source_file = b.path("src/apps/term/screen.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "font", .module = term_font_mod },
        },
    });

    const term_vt100_mod = b.createModule(.{
        .root_source_file = b.path("src/apps/term/vt100.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "screen", .module = term_screen_mod },
        },
    });

    const term_pty_mod = b.createModule(.{
        .root_source_file = b.path("src/apps/term/pty.zig"),
        .target = target,
        .optimize = optimize,
    });

    const term_renderer_mod = b.createModule(.{
        .root_source_file = b.path("src/apps/term/renderer.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "semadraw", .module = semadraw_mod },
            .{ .name = "screen", .module = term_screen_mod },
            .{ .name = "font", .module = term_font_mod },
        },
    });

    // semadraw-term terminal emulator
    const semadraw_term = b.addExecutable(.{
        .name = "semadraw-term",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/apps/term/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "semadraw_client", .module = client_mod },
                .{ .name = "semadraw", .module = semadraw_mod },
                .{ .name = "screen", .module = term_screen_mod },
                .{ .name = "vt100", .module = term_vt100_mod },
                .{ .name = "pty", .module = term_pty_mod },
                .{ .name = "renderer", .module = term_renderer_mod },
                .{ .name = "font", .module = term_font_mod },
            },
        }),
    });
    semadraw_term.root_module.link_libc = true;
    b.installArtifact(semadraw_term);

    // semadraw-demo graphics demo
    const semadraw_demo = b.addExecutable(.{
        .name = "semadraw-demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/apps/graphics_demo/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "semadraw_client", .module = client_mod },
                .{ .name = "semadraw", .module = semadraw_mod },
            },
        }),
    });
    b.installArtifact(semadraw_demo);

    // Unit tests
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/sdcs.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_tests = b.addRunArtifact(tests);

    // SIMD unit tests
    const simd_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/simd.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_simd_tests = b.addRunArtifact(simd_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_tests.step);
    test_step.dependOn(&run_simd_tests.step);
    // Note: bsdinput tests are in src/backend/bsdinput.zig but not included here
    // due to circular module dependencies. Run manually on FreeBSD if needed:
    // zig test src/backend/bsdinput.zig -lc -linput -ludev
}
