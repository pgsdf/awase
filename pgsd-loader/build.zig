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
    const tgt_step = b.step("test-target", "Build the emulation chainload stand-in");
    tgt_step.dependOn(&b.addInstallArtifact(tgt, .{}).step);
}
