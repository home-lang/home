const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const threading_futex_module = b.createModule(.{
        .root_source_file = b.path("../runtime/src/threading/Futex.zig"),
        .target = target,
        .optimize = optimize,
    });
    const threading_module = b.createModule(.{
        .root_source_file = b.path("../threading/src/threading.zig"),
        .target = target,
        .optimize = optimize,
    });
    threading_module.addImport("threading_futex", threading_futex_module);

    const scheduler_module = b.addModule("scheduler", .{
        .root_source_file = b.path("src/scheduler.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    scheduler_module.addImport("threading", threading_module);

    const lib = b.addLibrary(.{
        .name = "scheduler",
        .linkage = .static,
        .root_module = scheduler_module,
    });
    b.installArtifact(lib);

    const unit_tests = b.addTest(.{ .root_module = scheduler_module });

    const check_step = b.step("check", "Compile the shipped scheduler library and its tests");
    check_step.dependOn(&lib.step);
    check_step.dependOn(&unit_tests.step);

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run scheduler tests");
    test_step.dependOn(&run_unit_tests.step);
}
