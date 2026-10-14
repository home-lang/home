const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Dependencies
    const video_dep = b.dependency("video", .{
        .target = target,
        .optimize = optimize,
    });
    const video_module = video_dep.module("video");

    const audio_dep = b.dependency("audio", .{
        .target = target,
        .optimize = optimize,
    });
    const audio_module = audio_dep.module("audio");

    const image_dep = b.dependency("image", .{
        .target = target,
        .optimize = optimize,
    });
    const image_module = image_dep.module("image");

    // Main media library module
    const media_module = b.addModule("media", .{
        .root_source_file = b.path("src/media.zig"),
        .target = target,
        .optimize = optimize,
    });
    media_module.addImport("video", video_module);
    media_module.addImport("audio", audio_module);
    media_module.addImport("image", image_module);

    const lib = b.addLibrary(.{
        .name = "media",
        .linkage = .static,
        .root_module = media_module,
    });
    b.installArtifact(lib);

    // Unit tests with dependencies
    const unit_tests = b.addTest(.{ .root_module = media_module });

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // Integration tests
    const integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/media_tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    integration_tests.root_module.addImport("media", media_module);
    integration_tests.root_module.addImport("video", video_module);
    integration_tests.root_module.addImport("audio", audio_module);
    integration_tests.root_module.addImport("image", image_module);

    const check_step = b.step("check", "Compile the shipped media library and all tests");
    check_step.dependOn(&lib.step);
    check_step.dependOn(&unit_tests.step);
    check_step.dependOn(&integration_tests.step);

    const run_integration_tests = b.addRunArtifact(integration_tests);
    const integration_step = b.step("test-integration", "Run integration tests");
    integration_step.dependOn(&run_integration_tests.step);

    // All tests
    const all_tests_step = b.step("test-all", "Run all tests");
    all_tests_step.dependOn(&run_unit_tests.step);
    all_tests_step.dependOn(&run_integration_tests.step);
}
