const std = @import("std");

// pgsd-loader: stage L0 (ADR 0003). Built exclusively for the
// x86_64-uefi target with the vendored pinned toolchain
// (tools/bootstrap.sh, sdk/zig/current).
pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .uefi,
        .abi = .msvc,
    });

    const loader = b.addExecutable(.{
        .name = "pgsd-loader",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    loader.subsystem = .efi_application;
    b.installArtifact(loader);

    // Emulation-only chainload stand-in (never deployed): built via
    // `zig build test-target` for qemu/OVMF smoke runs.
    const tgt = b.addExecutable(.{
        .name = "chainload-target",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/chainload_target.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    tgt.subsystem = .efi_application;
    // option-launcher: emulation-only criterion 5 harness, starts
    // pgsd-loader with a known option string (never deployed).
    const launcher = b.addExecutable(.{
        .name = "option-launcher",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/option_launcher.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    launcher.subsystem = .efi_application;

    // Host-side tools (bas-selector): native target, never for
    // the ESP. zig build tools
    const host = b.resolveTargetQuery(.{});
    const seltool = b.addExecutable(.{
        .name = "bas-selector",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bas_selector_tool.zig"),
            .target = host,
            .optimize = optimize,
        }),
    });
    const mkfake = b.addExecutable(.{
        .name = "mk-fake-kernel",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/mk_fake_kernel.zig"),
            .target = host,
            .optimize = optimize,
        }),
    });

    const tools_step = b.step("tools", "Build host-side BAS tools");
    tools_step.dependOn(&b.addInstallArtifact(seltool, .{}).step);
    tools_step.dependOn(&b.addInstallArtifact(mkfake, .{}).step);

    const bas_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bas.zig"),
            .target = host,
            .optimize = optimize,
        }),
    });
    const test_step = b.step("test", "Run BAS record unit tests");
    test_step.dependOn(&b.addRunArtifact(bas_tests).step);

    const bas_launcher = b.addExecutable(.{
        .name = "bas-launcher",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/bas_launcher.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    bas_launcher.subsystem = .efi_application;

    const tgt_step = b.step("test-target", "Build the emulation test harnesses");
    tgt_step.dependOn(&b.addInstallArtifact(tgt, .{}).step);
    tgt_step.dependOn(&b.addInstallArtifact(launcher, .{}).step);
    tgt_step.dependOn(&b.addInstallArtifact(bas_launcher, .{}).step);
}
