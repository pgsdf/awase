const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // shared/src/clock.zig: dependency for all chronofs modules.
    const shared_clock_mod = b.createModule(.{
        .root_source_file = b.path("../shared/src/clock.zig"),
        .target = target,
        .optimize = optimize,
    });

    // shared/src/posix_safe.zig: AD-6 safe wrappers for kernel
    // cdev I/O. resolver uses safeRead in the ingestion thread.
    const posix_safe_mod = b.createModule(.{
        .root_source_file = b.path("../shared/src/posix_safe.zig"),
        .target = target,
        .optimize = optimize,
    });

    const posix_safe_tests = b.addTest(.{
        .root_module = posix_safe_mod,
    });

    // C-1: chronofs clock module.
    const clock_mod = b.createModule(.{
        .root_source_file = b.path("src/clock.zig"),
        .target = target,
        .optimize = optimize,
    });
    clock_mod.addImport("shared_clock", shared_clock_mod);

    const clock_tests = b.addTest(.{
        .root_module = clock_mod,
    });

    // C-2: chronofs event stream ring buffers.
    const stream_mod = b.createModule(.{
        .root_source_file = b.path("src/stream.zig"),
        .target = target,
        .optimize = optimize,
    });

    const stream_tests = b.addTest(.{
        .root_module = stream_mod,
    });

    // C-3: chronofs resolver.
    const resolver_mod = b.createModule(.{
        .root_source_file = b.path("src/resolver.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "stream",     .module = stream_mod      },
            .{ .name = "clock",      .module = clock_mod       },
            .{ .name = "posix_safe", .module = posix_safe_mod  },
        },
    });

    const resolver_tests = b.addTest(.{
        .root_module = resolver_mod,
    });

    // CHN0002BACKLOG Stage 1: instant axis representation (ADR 0004).
    const instant_mod = b.createModule(.{
        .root_source_file = b.path("src/instant.zig"),
        .target = target,
        .optimize = optimize,
    });

    const instant_tests = b.addTest(.{
        .root_module = instant_mod,
    });

    // CHN0002BACKLOG Stage 1: TimeIndex core (ADRs 0002, 0003, 0005).
    const timeindex_mod = b.createModule(.{
        .root_source_file = b.path("src/timeindex.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "instant", .module = instant_mod },
        },
    });

    const timeindex_tests = b.addTest(.{
        .root_module = timeindex_mod,
    });

    // CHN0002BACKLOG Stage 3: TimelineMap + TimelineView (ADR 0004).
    const timeline_mod = b.createModule(.{
        .root_source_file = b.path("src/timeline.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "instant", .module = instant_mod },
            .{ .name = "clock", .module = clock_mod },
        },
    });

    const timeline_tests = b.addTest(.{
        .root_module = timeline_mod,
    });

    // C-5: chrono_dump diagnostic tool.
    const chrono_dump = b.addExecutable(.{
        .name = "chrono_dump",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/chrono_dump.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "resolver", .module = resolver_mod },
                .{ .name = "stream",   .module = stream_mod   },
                .{ .name = "clock",    .module = clock_mod    },
            },
        }),
    });
    b.installArtifact(chrono_dump);

    const run_dump = b.addRunArtifact(chrono_dump);
    if (b.args) |run_args| run_dump.addArgs(run_args);
    const run_step = b.step("run", "Run chrono_dump");
    run_step.dependOn(&run_dump.step);

    const test_step = b.step("test", "Run chronofs tests");
    test_step.dependOn(&b.addRunArtifact(clock_tests).step);
    test_step.dependOn(&b.addRunArtifact(stream_tests).step);
    test_step.dependOn(&b.addRunArtifact(resolver_tests).step);
    test_step.dependOn(&b.addRunArtifact(instant_tests).step);
    test_step.dependOn(&b.addRunArtifact(timeindex_tests).step);
    test_step.dependOn(&b.addRunArtifact(timeline_tests).step);
    test_step.dependOn(&b.addRunArtifact(posix_safe_tests).step);
}
