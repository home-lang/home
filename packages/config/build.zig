const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const config_module = b.addModule("config", .{
        .root_source_file = b.path("src/config.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lib = b.addLibrary(.{
        .name = "config",
        .linkage = .static,
        .root_module = config_module,
    });
    b.installArtifact(lib);

    const unit_tests = b.addTest(.{ .root_module = config_module });

    const check_step = b.step("check", "Compile the shipped config library and its tests");
    check_step.dependOn(&lib.step);
    check_step.dependOn(&unit_tests.step);

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run config tests");
    test_step.dependOn(&run_unit_tests.step);
}
