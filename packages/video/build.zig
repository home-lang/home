const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Dependencies
    const regex_dep = b.dependency("regex", .{
        .target = target,
        .optimize = optimize,
    });
    const regex_module = regex_dep.module("regex");

    const test_framework_dep = b.dependency("test_framework", .{
        .target = target,
        .optimize = optimize,
    });
    const test_framework_module = test_framework_dep.module("test_framework");

    // Main video library module
    const video_module = b.addModule("video", .{
        .root_source_file = b.path("src/video.zig"),
        .target = target,
        .optimize = optimize,
    });
    video_module.addImport("regex", regex_module);

    // Unit tests with dependencies
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/video.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    unit_tests.root_module.addImport("regex", regex_module);
    unit_tests.root_module.addImport("test_framework", test_framework_module);

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // Integration tests with test framework
    const integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration_tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    integration_tests.root_module.addImport("video", video_module);
    integration_tests.root_module.addImport("regex", regex_module);
    integration_tests.root_module.addImport("test_framework", test_framework_module);

    const run_integration_tests = b.addRunArtifact(integration_tests);
    const integration_step = b.step("test-integration", "Run integration tests");
    integration_step.dependOn(&run_integration_tests.step);

    // Conformance tests
    const conformance_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/conformance_tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    conformance_tests.root_module.addImport("video", video_module);
    conformance_tests.root_module.addImport("test_framework", test_framework_module);

    const run_conformance_tests = b.addRunArtifact(conformance_tests);
    const conformance_step = b.step("test-conformance", "Run conformance tests");
    conformance_step.dependOn(&run_conformance_tests.step);

    // All tests
    const all_tests_step = b.step("test-all", "Run all tests");
    all_tests_step.dependOn(&run_unit_tests.step);
    all_tests_step.dependOn(&run_integration_tests.step);
    all_tests_step.dependOn(&run_conformance_tests.step);

    // Export module for use as dependency
    _ = video_module;
}
