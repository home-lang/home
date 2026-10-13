const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const i18n_module = b.addModule("i18n", .{
        .root_source_file = b.path("src/i18n.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lib = b.addLibrary(.{
        .name = "i18n",
        .linkage = .static,
        .root_module = i18n_module,
    });
    b.installArtifact(lib);

    const unit_tests = b.addTest(.{ .root_module = i18n_module });

    const check_step = b.step("check", "Compile the shipped i18n library and its tests");
    check_step.dependOn(&lib.step);
    check_step.dependOn(&unit_tests.step);

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run i18n tests");
    test_step.dependOn(&run_unit_tests.step);
}
