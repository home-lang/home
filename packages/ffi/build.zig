const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ========================================================================
    // FFI Module
    // ========================================================================

    const ffi_module = b.addModule("ffi", .{
        .root_source_file = b.path("src/ffi.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Basics dependency
    const basics_module = b.createModule(.{
        .root_source_file = b.path("../basics/src/basics.zig"),
        .target = target,
        .optimize = optimize,
    });
    ffi_module.addImport("basics", basics_module);

    // ========================================================================
    // Header Generation Module
    // ========================================================================

    const header_gen_module = b.addModule("header_gen", .{
        .root_source_file = b.path("src/header_gen.zig"),
        .target = target,
        .optimize = optimize,
    });
    header_gen_module.addImport("basics", basics_module);

    // ========================================================================
    // Tests
    // ========================================================================

    const ffi_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/ffi_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    ffi_tests.root_module.addImport("ffi", ffi_module);
    ffi_tests.root_module.addImport("header_gen", header_gen_module);
    ffi_tests.linkLibC(); // Link C standard library for testing

    const run_ffi_tests = b.addRunArtifact(ffi_tests);

    const test_step = b.step("test", "Run FFI tests");
    test_step.dependOn(&run_ffi_tests.step);

    // ========================================================================
    // Examples
    // ========================================================================

    // Math example
    const math_example = b.addExecutable(.{
        .name = "math_example",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/math_example.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    math_example.root_module.addImport("ffi", ffi_module);
    math_example.linkLibC();
    b.installArtifact(math_example);

    const run_math_example = b.addRunArtifact(math_example);
    const math_example_step = b.step("example-math", "Run math FFI example");
    math_example_step.dependOn(&run_math_example.step);

    // SQLite example (optional, requires sqlite3)
    const sqlite_example = b.addExecutable(.{
        .name = "sqlite_example",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/sqlite_example.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    sqlite_example.root_module.addImport("ffi", ffi_module);
    sqlite_example.linkLibC();
    sqlite_example.linkSystemLibrary("sqlite3");
    b.installArtifact(sqlite_example);

    const run_sqlite_example = b.addRunArtifact(sqlite_example);
    const sqlite_example_step = b.step("example-sqlite", "Run SQLite FFI example");
    sqlite_example_step.dependOn(&run_sqlite_example.step);

    // Run all examples
    const examples_step = b.step("examples", "Run all FFI examples");
    examples_step.dependOn(&run_math_example.step);
    // SQLite example is optional, uncomment if sqlite3 is installed
    // examples_step.dependOn(&run_sqlite_example.step);

    // ========================================================================
    // Documentation
    // ========================================================================

    const docs_install = b.addInstallDirectory(.{
        .source_dir = ffi_tests.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs/ffi",
    });

    const docs_step = b.step("docs", "Generate FFI documentation");
    docs_step.dependOn(&docs_install.step);
}
