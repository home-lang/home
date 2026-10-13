const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const validation_module = b.addModule("validation", .{
        .root_source_file = b.path("src/validation.zig"),
        .target = target,
        .optimize = optimize,
    });
    const messages_module = b.addModule("validation_messages", .{
        .root_source_file = b.path("src/messages.zig"),
        .target = target,
        .optimize = optimize,
    });
    const rules_module = b.addModule("validation_rules", .{
        .root_source_file = b.path("src/rules.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lib = b.addLibrary(.{
        .name = "validation",
        .linkage = .static,
        .root_module = validation_module,
    });
    b.installArtifact(lib);

    // Tests
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/validation_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    unit_tests.root_module.addImport("validation", validation_module);
    unit_tests.root_module.addImport("validation_messages", messages_module);
    unit_tests.root_module.addImport("validation_rules", rules_module);

    const message_tests = b.addTest(.{ .root_module = messages_module });
    const rule_tests = b.addTest(.{ .root_module = rules_module });

    const check_step = b.step("check", "Compile the shipped validation library and its tests");
    check_step.dependOn(&lib.step);
    check_step.dependOn(&unit_tests.step);
    check_step.dependOn(&message_tests.step);
    check_step.dependOn(&rule_tests.step);

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const run_message_tests = b.addRunArtifact(message_tests);
    const run_rule_tests = b.addRunArtifact(rule_tests);
    const test_step = b.step("test", "Run validation tests");
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&run_message_tests.step);
    test_step.dependOn(&run_rule_tests.step);
}
