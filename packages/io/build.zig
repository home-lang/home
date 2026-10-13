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
    const collections_module = b.addModule("collections", .{
        .root_source_file = b.path("../collections/src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    io_module.addImport("collections", collections_module);

    const lib = b.addLibrary(.{
        .name = "io",
        .linkage = .static,
        .root_module = io_module,
    });
    b.installArtifact(lib);

    // Unit tests embedded in the package sources.
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lib.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    unit_tests.root_module.addImport("collections", collections_module);

    // Public-package tests compile through the same module consumers import.
    const public_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/io_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    public_tests.root_module.addImport("io", io_module);

    const check_step = b.step("check", "Compile the shipped I/O library and its tests");
    check_step.dependOn(&lib.step);
    check_step.dependOn(&unit_tests.step);
    check_step.dependOn(&public_tests.step);

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const run_public_tests = b.addRunArtifact(public_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&run_public_tests.step);
}
