const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const queue_module = b.addModule("queue", .{
        .root_source_file = b.path("src/queue.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const lib = b.addLibrary(.{
        .name = "queue",
        .linkage = .static,
        .root_module = queue_module,
    });
    b.installArtifact(lib);

    const unit_tests = b.addTest(.{ .root_module = queue_module });

    const check_step = b.step("check", "Compile the shipped queue library and its tests");
    check_step.dependOn(&lib.step);
    check_step.dependOn(&unit_tests.step);

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run queue tests");
    test_step.dependOn(&run_unit_tests.step);
}
