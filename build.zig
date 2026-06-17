const std = @import("std");
const builtin = @import("builtin");

// Awase pins its toolchain to Zig 0.16.x, vendored under sdk/zig/current
// and fetched by tools/bootstrap.sh. This guard fails the build
// immediately under any other compiler, so a stray system Zig (0.15.2, a
// 0.17 dev build, ...) can never silently build part of the tree. This is
// what prevents the bench-green / dev-red class of confusion. Build via
// ./tools/zig, which execs the vendored compiler. See
// docs/dev/zig-0.16-migration.md.
comptime {
    const v = builtin.zig_version;
    if (v.major != 0 or v.minor != 16) {
        @compileError(std.fmt.comptimePrint(
            "Awase requires Zig 0.16.x; this compiler is {d}.{d}.{d}. Build via ./tools/zig.",
            .{ v.major, v.minor, v.patch },
        ));
    }
}

// ============================================================================
// Awase root build - delegates to each subproject.
//
// Requires bare metal FreeBSD 15. Virtualisation is not supported.
//
// Steps:
//   zig build              - build all subprojects
//   zig build test         - run all test suites
//   zig build build-semasound / build-semainput / build-semadraw / build-chronofs / build-pgsd-sessiond
//   zig build test-semasound / test-semainput / test-semadraw / test-chronofs / test-pgsd-sessiond
//   zig build run-semadraw - build and run semadrawd
//   zig build chrono-dump  - build chrono_dump
// ============================================================================

pub fn build(b: *std.Build) void {
    const target   = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    _ = target;
    _ = optimize;

    const subprojects = [_]struct {
        name: []const u8,
        dir:  []const u8,
    }{
        .{ .name = "semasound",      .dir = "semasound"      },
        .{ .name = "semainput",      .dir = "semainput"      },
        .{ .name = "semadraw",       .dir = "semadraw"       },
        .{ .name = "chronofs",       .dir = "chronofs"       },
        .{ .name = "pgsd-sessiond",  .dir = "pgsd-sessiond"  },
    };

    const build_all   = b.step("all",  "Build all subprojects (default)");
    const test_all    = b.step("test", "Run all test suites");
    const install_all = b.default_step;

    for (subprojects) |sp| {
        const build_cmd = b.addSystemCommand(&.{ b.graph.zig_exe, "build" });
        build_cmd.setCwd(b.path(sp.dir));

        const build_step = b.step(
            b.fmt("build-{s}", .{sp.name}),
            b.fmt("Build {s}", .{sp.name}),
        );
        build_step.dependOn(&build_cmd.step);
        build_all.dependOn(&build_cmd.step);
        install_all.dependOn(&build_cmd.step);

        const test_cmd = b.addSystemCommand(&.{ b.graph.zig_exe, "build", "test" });
        test_cmd.setCwd(b.path(sp.dir));

        const test_step = b.step(
            b.fmt("test-{s}", .{sp.name}),
            b.fmt("Test {s}", .{sp.name}),
        );
        test_step.dependOn(&test_cmd.step);
        test_all.dependOn(&test_cmd.step);
    }

    // -----------------------------------------------------------------------
    // Convenience run steps
    // -----------------------------------------------------------------------

    const run_semadraw = b.step("run-semadraw", "Build and run semadrawd (compositor)");
    {
        const build_cmd = b.addSystemCommand(&.{ b.graph.zig_exe, "build" });
        build_cmd.setCwd(b.path("semadraw"));
        const run_cmd = b.addSystemCommand(&.{ "zig-out/bin/semadrawd" });
        run_cmd.setCwd(b.path("semadraw"));
        run_cmd.step.dependOn(&build_cmd.step);
        run_semadraw.dependOn(&run_cmd.step);
    }

    const chrono_dump = b.step("chrono-dump", "Build chrono_dump diagnostic tool");
    {
        const build_cmd = b.addSystemCommand(&.{ b.graph.zig_exe, "build" });
        build_cmd.setCwd(b.path("chronofs"));
        chrono_dump.dependOn(&build_cmd.step);
    }
}
