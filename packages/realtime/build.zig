const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const realtime_mod = b.addModule("realtime", .{
        .root_source_file = b.path("src/realtime.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lib = b.addStaticLibrary(.{
        .name = "realtime",
        .root_source_file = b.path("src/realtime.zig"),
        .target = target,
        .optimize = optimize,
    });

    b.installArtifact(lib);

    const unit_tests = b.addTest(.{
        .root_source_file = b.path("src/realtime.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run realtime tests");
    test_step.dependOn(&run_unit_tests.step);

    _ = realtime_mod;
}
