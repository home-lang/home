const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Create module
    const io_module = b.addModule("io", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Add collections as dependency
    const collections_path = b.pathFromRoot("../collections/src/lib.zig");
    const collections_module = b.addModule("collections", .{
        .root_source_file = .{ .cwd_relative = collections_path },
        .target = target,
        .optimize = optimize,
    });

    io_module.addImport("collections", collections_module);

    // Tests
    const tests = b.addTest(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    tests.root_module.addImport("collections", collections_module);

    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_tests.step);
}
