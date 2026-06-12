const std = @import("std");

// AD-2a Phase 3 step 2: the semainputd daemon was retired
// 2026-05-08. This build script previously produced the
// semainputd executable from semainput/src/semainputd.zig
// plus its source-only dependencies (device_*.zig, output.zig,
// gesture.zig as a libsemainput shim, etc). All of that lives
// upstream in semadrawd now: input arrives from the inputfs
// event ring, gesture recognition runs as a service inside the
// compositor (Phase 2.4 recogniser-as-service decision), and
// the legacy DRAWFSGIOC_INJECT_INPUT path is gone from the
// userland tree.
//
// What remains under semainput/ is libsemainput — the
// recogniser library that semadrawd consumes via build.zig
// addImport. The library has no IO, no daemon scaffolding,
// and no semainputd-era source-only dependencies; it is just
// the gesture recogniser logic.
//
// This file therefore builds nothing executable. It exposes
// a `test` step so the top-level `zig build test` dispatcher
// (build.zig in the repo root, which runs `zig build test`
// in each subproject) finds something to run.

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // libsemainput — userland gesture recognition library.
    // Per ADR 0016, the library does no IO and depends only on
    // std. Consumed by semadrawd (semadraw/build.zig:605).
    const libsemainput_mod = b.createModule(.{
        .root_source_file = b.path("libsemainput/libsemainput.zig"),
        .target = target,
        .optimize = optimize,
    });

    // libsemainput tests — recogniser-level tests live in
    // libsemainput/libsemainput.zig. Wired here so `zig build test`
    // catches regressions (n-click cadence, drag/tap thresholds,
    // FIFO ordering, type-size budget).
    const libsemainput_tests = b.addTest(.{
        .root_module = libsemainput_mod,
    });

    const test_step = b.step("test", "Run libsemainput tests");
    test_step.dependOn(&b.addRunArtifact(libsemainput_tests).step);
}
