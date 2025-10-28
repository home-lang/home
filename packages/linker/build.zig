const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Create linker module
    const linker_module = b.addModule("linker", .{
        .root_source_file = b.path("src/linker.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Unit tests
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/linker.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);

    // Integration tests
    const integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/linker_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    integration_tests.root_module.addImport("linker", linker_module);

    const run_integration_tests = b.addRunArtifact(integration_tests);

    // Test step
    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&run_integration_tests.step);

    // Examples
    const kernel_example = b.addExecutable(.{
        .name = "kernel_example",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/kernel_example.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    kernel_example.root_module.addImport("linker", linker_module);

    const higher_half_example = b.addExecutable(.{
        .name = "higher_half_example",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/higher_half_example.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    higher_half_example.root_module.addImport("linker", linker_module);

    const embedded_example = b.addExecutable(.{
        .name = "embedded_example",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/embedded_example.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    embedded_example.root_module.addImport("linker", linker_module);

    const custom_example = b.addExecutable(.{
        .name = "custom_example",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/custom_example.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    custom_example.root_module.addImport("linker", linker_module);

    // Install examples
    b.installArtifact(kernel_example);
    b.installArtifact(higher_half_example);
    b.installArtifact(embedded_example);
    b.installArtifact(custom_example);

    // Run steps for examples
    const run_kernel = b.addRunArtifact(kernel_example);
    const run_higher_half = b.addRunArtifact(higher_half_example);
    const run_embedded = b.addRunArtifact(embedded_example);
    const run_custom = b.addRunArtifact(custom_example);

    const run_kernel_step = b.step("run-kernel", "Run kernel example");
    run_kernel_step.dependOn(&run_kernel.step);

    const run_higher_half_step = b.step("run-higher-half", "Run higher-half example");
    run_higher_half_step.dependOn(&run_higher_half.step);

    const run_embedded_step = b.step("run-embedded", "Run embedded example");
    run_embedded_step.dependOn(&run_embedded.step);

    const run_custom_step = b.step("run-custom", "Run custom example");
    run_custom_step.dependOn(&run_custom.step);

    // Run all examples
    const run_examples_step = b.step("run-examples", "Run all examples");
    run_examples_step.dependOn(&run_kernel.step);
    run_examples_step.dependOn(&run_higher_half.step);
    run_examples_step.dependOn(&run_embedded.step);
    run_examples_step.dependOn(&run_custom.step);
}
