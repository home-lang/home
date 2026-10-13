const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const notifications_module = b.addModule("notifications", .{
        .root_source_file = b.path("src/notifications.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lib = b.addLibrary(.{
        .name = "notifications",
        .linkage = .static,
        .root_module = notifications_module,
    });
    b.installArtifact(lib);

    const unit_tests = b.addTest(.{ .root_module = notifications_module });

    const check_step = b.step("check", "Compile the shipped notifications library and its tests");
    check_step.dependOn(&lib.step);
    check_step.dependOn(&unit_tests.step);

    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run all notification tests");
    test_step.dependOn(&run_unit_tests.step);
}
