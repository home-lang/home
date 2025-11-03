const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Collection module
    const collection_module = b.createModule(.{
        .root_source_file = b.path("src/collection.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Tests
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/collection_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    tests.root_module.addImport("collection", collection_module);

    const run_tests = b.addRunArtifact(tests);

    const test_step = b.step("test", "Run collections tests");
    test_step.dependOn(&run_tests.step);
}
