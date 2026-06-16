const std = @import("std");

pub fn build(b: *std.Build) void {
    const target   = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // -----------------------------------------------------------------------
    // Backend selection.
    //
    // All optional backends default to false. UTF's target platform is
    // PGSD on bare-metal FreeBSD 15, where graphics goes through drawfs
    // (not Vulkan) and input goes through inputfs (not libinput/libudev).
    // The PGSD distribution does not ship libvulkan, libX11, libinput,
    // or libudev as base packages, so a default-on configuration would
    // fail to build on the target platform.
    //
    // Linux developers and FreeBSD systems with the optional libraries
    // installed can opt in explicitly:
    //
    //   zig build -Dvulkan=true    # systems with libvulkan installed
    //   zig build -Dbsdinput=true  # systems with libinput and libudev
    //   zig build -Dx11=true       # FreeBSD with Xorg
    //   zig build -Dwayland=true   # systems with Wayland compositor
    //
    // The PGSD-default backends (drawfs for graphics, inputfs for input)
    // are always built; they are not optional.
    // -----------------------------------------------------------------------
    const want_x11     = b.option(bool, "x11",     "Enable X11 backend — requires libX11 (default: false)")              orelse false;
    const want_wayland = b.option(bool, "wayland",  "Enable Wayland backend — requires libwayland-client (default: false)") orelse false;
    const want_vulkan  = b.option(bool, "vulkan",   "Enable Vulkan backends — requires libvulkan (default: false)")       orelse false;
    const want_bsdinput = b.option(bool, "bsdinput", "Enable bsdinput — requires libinput and libudev (default: false)")  orelse false;

    const semadraw_root = b.path("src/semadraw.zig");
    const sdcs_root     = b.path("src/sdcs.zig");

    // Zig 0.15+ build API uses explicit root modules.
    //
    // semadraw_mod is exposed via b.addModule (not b.createModule) so
    // that sibling packages declaring semadraw as a build.zig.zon
    // dependency can pull it in via b.dependency("semadraw", ...).
    // The first external consumer is pgsd-sessiond's Stage 5 login UI.
    // Internal usage by this build.zig is unchanged: b.addModule
    // returns the same Module type b.createModule does.
    const semadraw_mod = b.addModule("semadraw", .{
        .root_source_file = semadraw_root,
        .target = target,
        .optimize = optimize,
    });
    const sdcs_mod = b.createModule(.{
        .root_source_file = sdcs_root,
        .target = target,
        .optimize = optimize,
    });

    // shared/src/compat.zig: Awase compatibility boundary over churning std
    // APIs (process args here; the std.posix socket shim joins later).
    // Exposed via b.addModule so downstream packages (pgsd-sessiond) can share
    // this single instance instead of creating a second module over the same
    // file, which 0.16 rejects (one file may root only one module).
    const compat_mod = b.addModule("compat", .{
        .root_source_file = b.path("../shared/src/compat.zig"),
        .target = target,
        .optimize = optimize,
    });
    semadraw_mod.addImport("compat", compat_mod);

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
    sdcs_dump.root_module.addImport("compat", compat_mod);
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
    sdcs_make_test.root_module.addImport("compat", compat_mod);
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
    sdcs_make_overlap.root_module.addImport("compat", compat_mod);
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
    sdcs_make_fractional.root_module.addImport("compat", compat_mod);
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
    sdcs_make_clip.root_module.addImport("compat", compat_mod);
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
    sdcs_make_transform.root_module.addImport("compat", compat_mod);
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
    sdcs_make_blend.root_module.addImport("compat", compat_mod);
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
	sdcs_make_stroke.root_module.addImport("compat", compat_mod);
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
	sdcs_make_line.root_module.addImport("compat", compat_mod);
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
	sdcs_make_join.root_module.addImport("compat", compat_mod);
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
	sdcs_make_join_round.root_module.addImport("compat", compat_mod);
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
	sdcs_make_cap.root_module.addImport("compat", compat_mod);
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
	sdcs_make_cap_round.root_module.addImport("compat", compat_mod);
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
	sdcs_make_miter_limit.root_module.addImport("compat", compat_mod);
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
	sdcs_make_diagonal.root_module.addImport("compat", compat_mod);
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
	sdcs_make_blit.root_module.addImport("compat", compat_mod);
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
	sdcs_make_curves.root_module.addImport("compat", compat_mod);
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
	sdcs_make_path.root_module.addImport("compat", compat_mod);
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
	sdcs_make_text.root_module.addImport("compat", compat_mod);
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
	sdcs_make_glyph.root_module.addImport("compat", compat_mod);
	b.installArtifact(sdcs_make_glyph);

	// AD-21 sub-item 4: cursor sprite generator. Run offline to
	// regenerate semadraw/assets/cursor_arrow.sdcs after a sprite
	// design change. Not part of the daemon's build dependency chain;
	// the daemon embeds the .sdcs file via @embedFile.
	const sdcs_make_cursor = b.addExecutable(.{
	    .name = "sdcs_make_cursor",
	    .root_module = b.createModule(.{
	        .root_source_file = b.path("src/tools/sdcs_make_cursor.zig"),
	        .target = target,
	        .optimize = optimize,
	    }),
	});
	sdcs_make_cursor.root_module.addImport("semadraw", semadraw_mod);
	sdcs_make_cursor.root_module.addImport("sdcs", sdcs_mod);
	sdcs_make_cursor.root_module.addImport("compat", compat_mod);
	b.installArtifact(sdcs_make_cursor);

	const sdcs_make_aa = b.addExecutable(.{
	    .name = "sdcs_make_aa",
	    .root_module = b.createModule(.{
	        .root_source_file = b.path("src/tools/sdcs_make_aa.zig"),
	        .target = target,
	        .optimize = optimize,
	    }),
	});
	sdcs_make_aa.root_module.addImport("semadraw", semadraw_mod);
	sdcs_make_aa.root_module.addImport("compat", compat_mod);
	b.installArtifact(sdcs_make_aa);

	const sdcs_make_fill = b.addExecutable(.{
	    .name = "sdcs_make_fill",
	    .root_module = b.createModule(.{
	        .root_source_file = b.path("src/tools/sdcs_make_fill.zig"),
	        .target = target,
	        .optimize = optimize,
	    }),
	});
	sdcs_make_fill.root_module.addImport("semadraw", semadraw_mod);
	sdcs_make_fill.root_module.addImport("compat", compat_mod);
	b.installArtifact(sdcs_make_fill);

	const sdcs_make_gradient = b.addExecutable(.{
	    .name = "sdcs_make_gradient",
	    .root_module = b.createModule(.{
	        .root_source_file = b.path("src/tools/sdcs_make_gradient.zig"),
	        .target = target,
	        .optimize = optimize,
	    }),
	});
	sdcs_make_gradient.root_module.addImport("semadraw", semadraw_mod);
	sdcs_make_gradient.root_module.addImport("compat", compat_mod);
	b.installArtifact(sdcs_make_gradient);

	const sdcs_make_pattern = b.addExecutable(.{
	    .name = "sdcs_make_pattern",
	    .root_module = b.createModule(.{
	        .root_source_file = b.path("src/tools/sdcs_make_pattern.zig"),
	        .target = target,
	        .optimize = optimize,
	    }),
	});
	sdcs_make_pattern.root_module.addImport("semadraw", semadraw_mod);
	sdcs_make_pattern.root_module.addImport("compat", compat_mod);
	b.installArtifact(sdcs_make_pattern);

	const sdcs_make_demo = b.addExecutable(.{
	    .name = "sdcs_make_demo",
	    .root_module = b.createModule(.{
	        .root_source_file = b.path("src/tools/sdcs_make_demo.zig"),
	        .target = target,
	        .optimize = optimize,
	    }),
	});
	sdcs_make_demo.root_module.addImport("semadraw", semadraw_mod);
	sdcs_make_demo.root_module.addImport("compat", compat_mod);
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
    sdcs_replay.root_module.addImport("compat", compat_mod);
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
    sdcs_test_malformed.root_module.addImport("compat", compat_mod);
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
    sdcs_fuzz.root_module.addImport("compat", compat_mod);
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
            .{ .name = "compat", .module = compat_mod },
            .{ .name = "session", .module = session_mod },
        },
    });

    // AD-31.2: privilege module: peer credentials, NOBODY sentinels,
    // future home of dropPrivileges and SEMADRAW_PRIVILEGED_UID
    // recognition (AD-31.3). Self-contained; relies on std.posix,
    // std.c, and a libc extern for getpeereid(3).
    const privilege_mod = b.createModule(.{
        .root_source_file = b.path("src/daemon/privilege.zig"),
        .target = target,
        .optimize = optimize,
    });

    const ipc_socket_mod = b.createModule(.{
        .root_source_file = b.path("src/ipc/socket_server.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "compat", .module = compat_mod },
            .{ .name = "protocol", .module = ipc_protocol_mod },
        },
    });

    const ipc_tcp_mod = b.createModule(.{
        .root_source_file = b.path("src/ipc/tcp_server.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "compat", .module = compat_mod },
            .{ .name = "protocol", .module = ipc_protocol_mod },
        },
    });

    const ipc_shm_mod = b.createModule(.{
        .root_source_file = b.path("src/ipc/shm.zig"),
        .target = target,
        .optimize = optimize,
    });
    ipc_shm_mod.addImport("compat", compat_mod);

    const client_session_mod = b.createModule(.{
        .root_source_file = b.path("src/daemon/client_session.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "protocol", .module = ipc_protocol_mod },
            .{ .name = "socket_server", .module = ipc_socket_mod },
            // AD-31.2: createSession calls privilege.getPeerCredentials
            // immediately after accept.
            .{ .name = "privilege", .module = privilege_mod },
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
            .{ .name = "compat", .module = compat_mod },
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
            .{ .name = "compat", .module = compat_mod },
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
    // shared/src/input.zig — inputfs event ring reader for AD-2a Phase 1.
    const shared_input_mod = b.createModule(.{
        .root_source_file = b.path("../shared/src/input.zig"),
        .target = target,
        .optimize = optimize,
    });

    // backend.zig references input.Event in its vtable signature for the
    // optional getInputfsEvents method (AD-2a Phase 2.4.2). The input
    // module must be available to backend_mod before any consumer
    // module imports backend.
    backend_mod.addImport("input", shared_input_mod);

    // semainput/libsemainput/libsemainput.zig — userland gesture
    // recognition library (AD-2a Phase 2.3 Stage B). Per ADR 0016,
    // the library does no IO and depends only on std. semadrawd
    // owns one GestureRecognizer instance starting at AD-2a Phase
    // 2.4.3; clients linking the library directly is also a
    // supported pattern (no clients do today).
    const libsemainput_mod = b.createModule(.{
        .root_source_file = b.path("../semainput/libsemainput/libsemainput.zig"),
        .target = target,
        .optimize = optimize,
    });

    const drawfs_backend_mod = b.createModule(.{
        .root_source_file = b.path("src/backend/drawfs.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "compat", .module = compat_mod },
            .{ .name = "backend", .module = backend_mod },
            .{ .name = "input", .module = shared_input_mod },
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
            .{ .name = "compat", .module = compat_mod },
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
            .{ .name = "compat", .module = compat_mod },
            .{ .name = "shared_clock", .module = shared_clock_mod },
        },
    });

    const compositor_mod = b.createModule(.{
        .root_source_file = b.path("src/compositor/compositor.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "compat", .module = compat_mod },
            .{ .name = "damage", .module = damage_mod },
            .{ .name = "frame_scheduler", .module = frame_scheduler_mod },
            .{ .name = "backend", .module = backend_mod },
            .{ .name = "surface_registry", .module = surface_registry_mod },
            .{ .name = "shared_clock", .module = shared_clock_mod },
            // AD-2a Phase 2.4.4: compositor exposes a getInputfsEvents
            // pass-through whose return slice type references
            // input.Event from shared/src/input.zig.
            .{ .name = "input", .module = shared_input_mod },
            // AD-25 instrumentation: compositor emits a per-cycle
            // diagnostic event via the unified event schema. Gated on
            // UTF_COMPOSITOR_INSTRUMENT at compositor construction.
            .{ .name = "events", .module = events_mod },
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
                .{ .name = "libsemainput", .module = libsemainput_mod },
                // AD-2a Phase 2.4.4: daemon translates input.Event values
                // pulled from the drawfs side-channel buffer into
                // LibsemainputInput before feeding the recogniser.
                .{ .name = "input", .module = shared_input_mod },
                // AD-21 sub-item 5: position pump constructs damage.Rect
                // values for cursor old/new positions and intersects them
                // with underlying surface bounds.
                .{ .name = "damage", .module = damage_mod },
                // AD-31.2: NOBODY_UID/GID sentinels used at TCP
                // RemoteSession construction; future AD-31.3 will use
                // more of this module's surface.
                .{ .name = "privilege", .module = privilege_mod },
            },
        }),
    });
    semadrawd.root_module.addImport("compat", compat_mod);
    b.installArtifact(semadrawd);

    // Client library modules
    const client_connection_mod = b.createModule(.{
        .root_source_file = b.path("src/client/connection.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "compat", .module = compat_mod },
            .{ .name = "protocol", .module = ipc_protocol_mod },
        },
    });

    const client_remote_mod = b.createModule(.{
        .root_source_file = b.path("src/client/remote_connection.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "compat", .module = compat_mod },
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

    // Wire client into semadraw_mod so app.zig can import semadraw_client
    semadraw_mod.addImport("semadraw_client", client_mod);

    // Client library (static)
    const client_lib = b.addLibrary(.{
        .name = "semadraw_client",
        .root_module = client_mod,
        .linkage = .static,
    });
    b.installArtifact(client_lib);

    // gesture_inspect — diagnostic CLI for AD-2a Phase 2.5
    // verification. Connects to semadrawd, registers a surface,
    // prints every key/mouse/gesture event the daemon sends to it.
    // See semadraw/docs/PHASE_2_5_VERIFICATION.md for the canonical
    // input scenarios this tool exercises.
    const gesture_inspect = b.addExecutable(.{
        .name = "gesture_inspect",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tools/gesture_inspect.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "semadraw_client", .module = client_mod },
            },
        }),
    });
    gesture_inspect.root_module.addImport("compat", compat_mod);
    b.installArtifact(gesture_inspect);

    // idle_probe - D-11 (ADR 0013) bench helper. Connects to semadrawd
    // and queries the published last_input_ts_ns via idle_query, in
    // one-shot or --watch mode. Verifies the idle signal on bare metal:
    // sentinel-0 before first input, per-class advance, non-root
    // freshness. See semadraw/docs/adr/0013-publish-last-input-timestamp.md.
    const idle_probe = b.addExecutable(.{
        .name = "idle_probe",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tools/idle_probe.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "semadraw_client", .module = client_mod },
            },
        }),
    });
    idle_probe.root_module.addImport("compat", compat_mod);
    b.installArtifact(idle_probe);

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
    term_pty_mod.addImport("compat", compat_mod);

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
    semadraw_term.root_module.addImport("compat", compat_mod);
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
    semadraw_demo.root_module.addImport("compat", compat_mod);
    b.installArtifact(semadraw_demo);

    // Hello — minimal App framework example
    const hello = b.addExecutable(.{
        .name = "hello",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/apps/hello/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "semadraw", .module = semadraw_mod },
            },
        }),
    });
    b.installArtifact(hello);
    const hello_step = b.step("hello", "Build the hello example app");
    hello_step.dependOn(&hello.step);

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

    // AD-2a Phase 1 tests — inputfs translation table (no module
    // imports needed, single-file unit tests).
    const inputfs_translate_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/backend/inputfs_translate.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_inputfs_translate_tests = b.addRunArtifact(inputfs_translate_tests);

    // IPC protocol tests — wire-format round-trip and size invariants.
    // Lives at the same level as inputfs_translate_tests above (single-
    // file unit tests, no module imports needed).
    const ipc_protocol_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/ipc/protocol.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_ipc_protocol_tests = b.addRunArtifact(ipc_protocol_tests);

    // Client connection tests — gesture event decoding (parseGestureEvent
    // round-trips, void-payload handling, truncated-buffer rejection,
    // unknown-gesture-type forward-compat). connection.zig imports
    // protocol, so the test target needs the same module wiring as
    // any other consumer.
    const client_connection_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/client/connection.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "protocol", .module = ipc_protocol_mod },
                .{ .name = "compat", .module = compat_mod },
            },
        }),
    });
    const run_client_connection_tests = b.addRunArtifact(client_connection_tests);

    // Note: tests inside src/backend/inputfs_input.zig are NOT wired
    // into the test step. inputfs_input.zig is also imported as a
    // file by src/backend/drawfs.zig (via `@import("inputfs_input.zig")`),
    // and Zig 0.15 forbids a single file from being the root of one
    // module while also being a transitive file of another.
    //
    // The tests in inputfs_input.zig include regression coverage for
    // the pointer-event-duplication fix (motion-with-mask + explicit
    // button events were both emitting press/release transitions,
    // doubling every click on the wire). They're runnable manually
    // from the semadraw/ directory via:
    //
    //   zig test --dep backend --dep input \
    //       -Mroot=src/backend/inputfs_input.zig \
    //       -Mbackend=src/backend/backend.zig \
    //       -Minput=../shared/src/input.zig
    //
    // Promoting inputfs_input.zig to a build-system module would
    // wire it in cleanly, but the resulting drawfs_backend_mod would
    // hit a "file exists in modules 'root' and 'inputfs_input'"
    // error because backend_mod.addImport("drawfs", ...) creates a
    // path back through to the same file. Resolving that is a
    // larger restructure; the regression tests stand on their own
    // when run manually, and the pre-existing mapButtonBit test
    // had the same status.

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_tests.step);
    test_step.dependOn(&run_simd_tests.step);
    test_step.dependOn(&run_inputfs_translate_tests.step);
    test_step.dependOn(&run_ipc_protocol_tests.step);
    test_step.dependOn(&run_client_connection_tests.step);
    // Note: bsdinput tests are in src/backend/bsdinput.zig but not included here
    // due to circular module dependencies. Run manually on FreeBSD if needed:
    // zig test src/backend/bsdinput.zig -lc -linput -ludev
}
