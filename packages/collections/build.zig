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

    // Lazy collection module
    const lazy_collection_module = b.createModule(.{
        .root_source_file = b.path("src/lazy_collection.zig"),
        .target = target,
        .optimize = optimize,
    });
    lazy_collection_module.addImport("collection", collection_module);

    // Collection tests
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/collection_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    tests.root_module.addImport("collection", collection_module);

    // Lazy collection tests
    const lazy_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/lazy_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    lazy_tests.root_module.addImport("lazy_collection", lazy_collection_module);
    lazy_tests.root_module.addImport("collection", collection_module);

    const run_tests = b.addRunArtifact(tests);
    const run_lazy_tests = b.addRunArtifact(lazy_tests);

    const test_step = b.step("test", "Run all collections tests");
    test_step.dependOn(&run_tests.step);
    test_step.dependOn(&run_lazy_tests.step);
}
