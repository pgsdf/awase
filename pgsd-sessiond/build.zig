const std = @import("std");

// pgsd-sessiond: PGSD's graphical login provider.
//
// Stages 1-5: CLI tool for PAM auth, user enumeration,
// session-file enumeration, session-leader launch, and the
// minimal graphical login UI. Links:
//   - libpam (OpenPAM in FreeBSD base): -lpam
//   - login_cap, setusercontext (FreeBSD): -lutil
//   - libc (for sysctlbyname, getifaddrs, gethostname)
//
// Stage 5 added a build-time dependency on the semadraw subproject
// for the App framework, Encoder, and AppEvent types. Resolved via
// build.zig.zon's .path = "../semadraw" relative to this package.
//
// See pgsd-sessiond/README.md for component overview and
// pgsd-sessiond/docs/adr/ for the design ADRs.

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // semadraw dependency. b.dependency() resolves via build.zig.zon's
    // .path entry to ../semadraw. dep.module("semadraw") retrieves the
    // public module that semadraw's build.zig exposes via b.addModule.
    const semadraw_dep = b.dependency("semadraw", .{
        .target = target,
        .optimize = optimize,
    });
    const semadraw_mod = semadraw_dep.module("semadraw");

    // shared/src/compat.zig: Awase compatibility boundary over churning std
    // APIs. Reuse the instance semadraw exposes rather than creating a second
    // module over the same file: main imports compat directly and also pulls it
    // in transitively through semadraw, and 0.16 forbids one file rooting two
    // modules (the compat/compat0 collision). Sharing semadraw's instance keeps
    // a single compat module across the whole graph.
    const compat_mod = semadraw_dep.module("compat");

    const exe = b.addExecutable(.{
        .name = "pgsd-sessiond",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "semadraw", .module = semadraw_mod },
                .{ .name = "compat", .module = compat_mod },
            },
        }),
    });

    // FreeBSD libpam (OpenPAM in base): -lpam.
    // FreeBSD login_cap: -lutil (contains login_cap, setusercontext).
    exe.root_module.linkSystemLibrary("pam", .{});
    exe.root_module.linkSystemLibrary("util", .{});
    exe.root_module.link_libc = true;

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run pgsd-sessiond");
    run_step.dependOn(&run_cmd.step);

    // Test step. Nine test surfaces:
    //   - pam.zig: libpam binding wrapper with mock conversation.
    //   - attribute_file.zig: /etc/utf/users/<name>.conf parser (ADR 0003).
    //   - user_enum.zig: pure-function helpers for /etc/master.passwd.
    //   - session_file.zig: ADR 0004 .session parser + enumerator.
    //   - launch.zig: env construction + filter-name helper.
    //   - keymap.zig: evdev keycode -> Action translation (Stage 5).
    //   - sysinfo.zig: hostname / sysctl / getifaddrs helpers (Stage 5).
    //   - ui.zig: login UI state-machine transitions (Stage 5).
    //   - main.zig: argument parsing.
    const pam_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/pam.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    pam_tests.root_module.linkSystemLibrary("pam", .{});
    pam_tests.root_module.link_libc = true;

    const attribute_file_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/attribute_file.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    attribute_file_tests.root_module.link_libc = true;

    const user_enum_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/user_enum.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    user_enum_tests.root_module.link_libc = true;

    const session_file_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/session_file.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    session_file_tests.root_module.link_libc = true;

    const launch_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/launch.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    launch_tests.root_module.linkSystemLibrary("pam", .{});
    launch_tests.root_module.linkSystemLibrary("util", .{});
    launch_tests.root_module.link_libc = true;

    const keymap_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/keymap.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const sysinfo_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/sysinfo.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    sysinfo_tests.root_module.link_libc = true;

    // ui.zig imports semadraw plus the other sibling modules via
    // relative @import. For the test build we expose semadraw as a
    // named import; font.zig, keymap.zig, sysinfo.zig are picked up
    // via relative @import from ui.zig's own source path.
    const ui_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/ui.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "semadraw", .module = semadraw_mod },
            },
        }),
    });
    ui_tests.root_module.link_libc = true;

    const main_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    const test_step = b.step("test", "Run pgsd-sessiond tests");
    test_step.dependOn(&b.addRunArtifact(pam_tests).step);
    test_step.dependOn(&b.addRunArtifact(attribute_file_tests).step);
    test_step.dependOn(&b.addRunArtifact(user_enum_tests).step);
    test_step.dependOn(&b.addRunArtifact(session_file_tests).step);
    test_step.dependOn(&b.addRunArtifact(launch_tests).step);
    test_step.dependOn(&b.addRunArtifact(keymap_tests).step);
    test_step.dependOn(&b.addRunArtifact(sysinfo_tests).step);
    test_step.dependOn(&b.addRunArtifact(ui_tests).step);
    test_step.dependOn(&b.addRunArtifact(main_tests).step);
}
