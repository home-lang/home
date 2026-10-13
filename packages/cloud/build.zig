const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const cloud_module = b.addModule("cloud", .{
        .root_source_file = b.path("src/cloud.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Shipped library
    const lib = b.addLibrary(.{
        .name = "cloud",
        .linkage = .static,
        .root_module = cloud_module,
    });

    b.installArtifact(lib);

    // cloud.zig explicitly references every runtime service declaration, so
    // this single artifact covers the public root and all service tests.
    const test_step = b.step("test", "Run all cloud tests");
    const tests = b.addTest(.{
        .name = "test-cloud",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cloud.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(tests).step);
}
