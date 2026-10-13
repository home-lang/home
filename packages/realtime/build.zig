const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const realtime_mod = b.addModule("realtime", .{
        .root_source_file = b.path("src/realtime.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lib = b.addLibrary(.{
        .name = "realtime",
        .linkage = .static,
        .root_module = realtime_mod,
    });

    b.installArtifact(lib);

    const unit_tests = b.addTest(.{ .root_module = realtime_mod });
    const check_step = b.step("check", "Compile the shipped realtime library and its tests");
    check_step.dependOn(&lib.step);
    check_step.dependOn(&unit_tests.step);

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run realtime tests");
    test_step.dependOn(&run_unit_tests.step);
}
