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

    // Macros module
    const macros_module = b.createModule(.{
        .root_source_file = b.path("src/macros.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Traits module
    const traits_module = b.createModule(.{
        .root_source_file = b.path("src/traits.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Main collections library module
    const lib_module = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    lib_module.addImport("collection", collection_module);
    lib_module.addImport("lazy_collection", lazy_collection_module);
    lib_module.addImport("traits", traits_module);
    lib_module.addImport("macros", macros_module);

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

    // Macros tests
    const macros_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/macros_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    macros_tests.root_module.addImport("collection", collection_module);
    macros_tests.root_module.addImport("macros", macros_module);

    // Traits tests
    const traits_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/traits_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    traits_tests.root_module.addImport("traits", traits_module);

    const run_tests = b.addRunArtifact(tests);
    const run_lazy_tests = b.addRunArtifact(lazy_tests);
    const run_macros_tests = b.addRunArtifact(macros_tests);
    const run_traits_tests = b.addRunArtifact(traits_tests);

    const test_step = b.step("test", "Run all collections tests");
    test_step.dependOn(&run_tests.step);
    test_step.dependOn(&run_lazy_tests.step);
    test_step.dependOn(&run_macros_tests.step);
    test_step.dependOn(&run_traits_tests.step);

    // Example executables
    const basic_example = b.addExecutable(.{
        .name = "basic_usage",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/basic_usage.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    basic_example.root_module.addImport("collections", lib_module);

    const advanced_example = b.addExecutable(.{
        .name = "advanced_usage",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/advanced_usage.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    advanced_example.root_module.addImport("collections", lib_module);

    const install_basic = b.addInstallArtifact(basic_example, .{});
    const install_advanced = b.addInstallArtifact(advanced_example, .{});

    const examples_step = b.step("examples", "Build example executables");
    examples_step.dependOn(&install_basic.step);
    examples_step.dependOn(&install_advanced.step);

    const run_basic = b.addRunArtifact(basic_example);
    const run_advanced = b.addRunArtifact(advanced_example);

    const run_basic_step = b.step("run-basic", "Run basic usage example");
    run_basic_step.dependOn(&run_basic.step);

    const run_advanced_step = b.step("run-advanced", "Run advanced usage example");
    run_advanced_step.dependOn(&run_advanced.step);
}
