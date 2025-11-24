const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Main audio library module
    const audio_module = b.addModule("audio", .{
        .root_source_file = b.path("src/audio.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Unit tests (built-in Zig tests)
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/audio.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // Standalone integration tests using zig-test-framework
    const ztf_dep = b.dependency("zig-test-framework", .{
        .target = target,
        .optimize = optimize,
    });

    const integration_tests = b.addExecutable(.{
        .name = "audio-integration-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/audio_tests.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zig-test-framework", .module = ztf_dep.module("zig-test-framework") },
                .{ .name = "audio", .module = audio_module },
            },
        }),
    });

    b.installArtifact(integration_tests);

    const run_integration_tests = b.addRunArtifact(integration_tests);
    const integration_step = b.step("integration-test", "Run integration tests with zig-test-framework");
    integration_step.dependOn(&run_integration_tests.step);
}
