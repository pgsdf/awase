const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Session identity module.
    const session_mod = b.createModule(.{
        .root_source_file = b.path("src/session.zig"),
        .target = target,
        .optimize = optimize,
    });

    const session_tests = b.addTest(.{
        .root_module = session_mod,
    });

    // Clock publication module.
    const clock_mod = b.createModule(.{
        .root_source_file = b.path("src/clock.zig"),
        .target = target,
        .optimize = optimize,
    });

    const clock_tests = b.addTest(.{
        .root_module = clock_mod,
    });

    // Input publication module.
    const input_mod = b.createModule(.{
        .root_source_file = b.path("src/input.zig"),
        .target = target,
        .optimize = optimize,
    });

    const input_tests = b.addTest(.{
        .root_module = input_mod,
    });

    const test_step = b.step("test", "Run shared module tests");
    test_step.dependOn(&b.addRunArtifact(session_tests).step);
    test_step.dependOn(&b.addRunArtifact(clock_tests).step);
    test_step.dependOn(&b.addRunArtifact(input_tests).step);
}
