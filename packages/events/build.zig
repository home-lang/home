const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const threading_futex = b.createModule(.{
        .root_source_file = b.path("../runtime/src/threading/Futex.zig"),
        .target = target,
        .optimize = optimize,
    });
    const threading = b.createModule(.{
        .root_source_file = b.path("../threading/src/threading.zig"),
        .target = target,
        .optimize = optimize,
    });
    threading.addImport("threading_futex", threading_futex);

    const events_mod = b.addModule("events", .{
        .root_source_file = b.path("src/events.zig"),
        .target = target,
        .optimize = optimize,
    });
    events_mod.addImport("threading", threading);

    const lib = b.addLibrary(.{
        .name = "events",
        .linkage = .static,
        .root_module = events_mod,
    });

    b.installArtifact(lib);

    const unit_tests = b.addTest(.{ .root_module = events_mod });
    const check_step = b.step("check", "Compile the shipped events library and its tests");
    check_step.dependOn(&lib.step);
    check_step.dependOn(&unit_tests.step);

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run events tests");
    test_step.dependOn(&run_unit_tests.step);
}
