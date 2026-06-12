const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // shared/src/input.zig: the C.1 publication-region library.
    const shared_input_mod = b.createModule(.{
        .root_source_file = b.path("../shared/src/input.zig"),
        .target = target,
        .optimize = optimize,
    });

    // inputdump: the canonical CLI for reading inputfs publication
    // regions (state, events, focus). Subcommands: state, events,
    // watch, devices. Lands in C.4; replaces the C.2/C.3
    // inputstate-check throwaway.
    const inputdump = b.addExecutable(.{
        .name = "inputdump",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/inputdump.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "input", .module = shared_input_mod },
            },
        }),
    });
    b.installArtifact(inputdump);

    const run_inputdump = b.addRunArtifact(inputdump);
    if (b.args) |run_args| run_inputdump.addArgs(run_args);
    const run_step = b.step("run", "Run inputdump (pass arguments after -- )");
    run_step.dependOn(&run_inputdump.step);
}
