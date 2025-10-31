const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Create intrinsics module
    const intrinsics = b.addModule("intrinsics", .{
        .root_source_file = b.path("src/intrinsics.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Add tests
    const tests = b.addTest(.{
        .root_source_file = b.path("src/intrinsics.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_tests = b.addRunArtifact(tests);

    const test_step = b.step("test", "Run intrinsics tests");
    test_step.dependOn(&run_tests.step);

    _ = intrinsics;
}
