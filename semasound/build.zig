const std = @import("std");

// semasound: userland audio broker (AD-3 F.5). F.5.a is the mixer core and
// audiofs output path (ADR 0021). Greenfield per ADR 0020.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // shared/src/compat.zig: Awase compatibility boundary over churning std APIs.
    const compat_mod = b.createModule(.{
        .root_source_file = b.path("../shared/src/compat.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "semasound",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addImport("compat", compat_mod);
    b.installArtifact(exe);

    // semasound-tone: F.5.a test client.
    const tone = b.addExecutable(.{
        .name = "semasound-tone",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tone_client.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    tone.root_module.addImport("compat", compat_mod);
    b.installArtifact(tone);

    // semasound-cat: generic stdin PCM client. Pairs with any external
    // decoder (ffmpeg et al.) to make arbitrary media a semasound source.
    const cat = b.addExecutable(.{
        .name = "semasound-cat",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cat_client.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    cat.root_module.addImport("compat", compat_mod);
    b.installArtifact(cat);

    // F.5.e (ADR 0027 Decision 5): the read-only surface inspector.
    const dump = b.addExecutable(.{
        .name = "semasound-dump",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/semasound_dump.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    dump.root_module.addImport("compat", compat_mod);
    b.installArtifact(dump);

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run semasound");
    run_step.dependOn(&run_cmd.step);

    // resampler_quality: F.5.b signal-quality harness (ADR 0024 criterion 4).
    // Test-only; built and run via `zig build resampler-quality`.
    const rq = b.addExecutable(.{
        .name = "resampler_quality",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/resampler_quality.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const rq_run = b.addRunArtifact(rq);
    const rq_step = b.step("resampler-quality", "Run the resampler signal-quality harness");
    rq_step.dependOn(&rq_run.step);

    // Unit tests: the pure/verifiable modules.
    const test_step = b.step("test", "Run semasound tests");
    inline for (.{ "src/mixer.zig", "src/protocol.zig", "src/ring.zig", "src/resampler.zig", "src/predictor.zig", "src/estimator.zig", "src/election.zig", "src/target.zig", "src/policy.zig", "src/events.zig", "src/state.zig" }) |path| {
        const tmod = b.createModule(.{
            .root_source_file = b.path(path),
            .target = target,
            .optimize = optimize,
        });
        tmod.addImport("compat", compat_mod);
        const t = b.addTest(.{
            .root_module = tmod,
        });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }
}
