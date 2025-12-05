const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Library
    const lib = b.addStaticLibrary(.{
        .name = "aws",
        .root_source_file = b.path("src/aws.zig"),
        .target = target,
        .optimize = optimize,
    });

    b.installArtifact(lib);

    // Module for use as dependency
    _ = b.addModule("aws", .{
        .root_source_file = b.path("src/aws.zig"),
    });

    // Tests
    const lib_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/aws.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
}
