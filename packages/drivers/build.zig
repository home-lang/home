const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Create drivers module
    const drivers_mod = b.addModule("drivers", .{
        .root_source_file = b.path("src/drivers.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Unit tests
    const drivers_test_mod = b.createModule(.{
        .root_source_file = b.path("src/drivers.zig"),
        .target = target,
        .optimize = optimize,
    });
    const drivers_tests = b.addTest(.{
        .root_module = drivers_test_mod,
    });

    const pci_test_mod = b.createModule(.{
        .root_source_file = b.path("src/pci.zig"),
        .target = target,
        .optimize = optimize,
    });
    const pci_tests = b.addTest(.{
        .root_module = pci_test_mod,
    });

    const acpi_test_mod = b.createModule(.{
        .root_source_file = b.path("src/acpi.zig"),
        .target = target,
        .optimize = optimize,
    });
    const acpi_tests = b.addTest(.{
        .root_module = acpi_test_mod,
    });

    const graphics_test_mod = b.createModule(.{
        .root_source_file = b.path("src/graphics.zig"),
        .target = target,
        .optimize = optimize,
    });
    const graphics_tests = b.addTest(.{
        .root_module = graphics_test_mod,
    });

    const input_test_mod = b.createModule(.{
        .root_source_file = b.path("src/input.zig"),
        .target = target,
        .optimize = optimize,
    });
    const input_tests = b.addTest(.{
        .root_module = input_test_mod,
    });

    const run_drivers_tests = b.addRunArtifact(drivers_tests);
    const run_pci_tests = b.addRunArtifact(pci_tests);
    const run_acpi_tests = b.addRunArtifact(acpi_tests);
    const run_graphics_tests = b.addRunArtifact(graphics_tests);
    const run_input_tests = b.addRunArtifact(input_tests);

    const test_step = b.step("test", "Run all driver tests");
    test_step.dependOn(&run_drivers_tests.step);
    test_step.dependOn(&run_pci_tests.step);
    test_step.dependOn(&run_acpi_tests.step);
    test_step.dependOn(&run_graphics_tests.step);
    test_step.dependOn(&run_input_tests.step);

    // Examples
    const pci_example_mod = b.createModule(.{
        .root_source_file = b.path("examples/pci_example.zig"),
        .target = target,
        .optimize = optimize,
    });
    pci_example_mod.addImport("drivers", drivers_mod);
    const pci_example = b.addExecutable(.{
        .name = "pci_example",
        .root_module = pci_example_mod,
    });

    const graphics_example_mod = b.createModule(.{
        .root_source_file = b.path("examples/graphics_example.zig"),
        .target = target,
        .optimize = optimize,
    });
    graphics_example_mod.addImport("drivers", drivers_mod);
    const graphics_example = b.addExecutable(.{
        .name = "graphics_example",
        .root_module = graphics_example_mod,
    });

    const input_example_mod = b.createModule(.{
        .root_source_file = b.path("examples/input_example.zig"),
        .target = target,
        .optimize = optimize,
    });
    input_example_mod.addImport("drivers", drivers_mod);
    const input_example = b.addExecutable(.{
        .name = "input_example",
        .root_module = input_example_mod,
    });

    const run_pci_example = b.addRunArtifact(pci_example);
    const run_graphics_example = b.addRunArtifact(graphics_example);
    const run_input_example = b.addRunArtifact(input_example);

    const pci_example_step = b.step("run-pci", "Run PCI enumeration example");
    pci_example_step.dependOn(&run_pci_example.step);

    const graphics_example_step = b.step("run-graphics", "Run graphics driver example");
    graphics_example_step.dependOn(&run_graphics_example.step);

    const input_example_step = b.step("run-input", "Run input driver example");
    input_example_step.dependOn(&run_input_example.step);

    const run_all_examples = b.step("run-examples", "Run all examples");
    run_all_examples.dependOn(&run_pci_example.step);
    run_all_examples.dependOn(&run_graphics_example.step);
    run_all_examples.dependOn(&run_input_example.step);

    // Install artifacts
    b.installArtifact(pci_example);
    b.installArtifact(graphics_example);
    b.installArtifact(input_example);
}
