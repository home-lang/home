const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Create variadic module
    const variadic_module = b.addModule("variadic", .{
        .root_source_file = b.path("src/variadic.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Unit tests
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/variadic.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);

    // Integration tests
    const integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/variadic_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    integration_tests.root_module.addImport("variadic", variadic_module);

    const run_integration_tests = b.addRunArtifact(integration_tests);

    // Test step
    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&run_integration_tests.step);

    // Examples
    const printf_example = b.addExecutable(.{
        .name = "printf_example",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/printf_example.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    printf_example.root_module.addImport("variadic", variadic_module);

    const logger_example = b.addExecutable(.{
        .name = "logger_example",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/logger_example.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    logger_example.root_module.addImport("variadic", variadic_module);

    const syscall_example = b.addExecutable(.{
        .name = "syscall_example",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/syscall_example.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    syscall_example.root_module.addImport("variadic", variadic_module);

    // Install examples
    b.installArtifact(printf_example);
    b.installArtifact(logger_example);
    b.installArtifact(syscall_example);

    // Run steps for examples
    const run_printf = b.addRunArtifact(printf_example);
    const run_logger = b.addRunArtifact(logger_example);
    const run_syscall = b.addRunArtifact(syscall_example);

    const run_printf_step = b.step("run-printf", "Run printf example");
    run_printf_step.dependOn(&run_printf.step);

    const run_logger_step = b.step("run-logger", "Run logger example");
    run_logger_step.dependOn(&run_logger.step);

    const run_syscall_step = b.step("run-syscall", "Run syscall example");
    run_syscall_step.dependOn(&run_syscall.step);

    // Run all examples
    const run_examples_step = b.step("run-examples", "Run all examples");
    run_examples_step.dependOn(&run_printf.step);
    run_examples_step.dependOn(&run_logger.step);
    run_examples_step.dependOn(&run_syscall.step);
}
