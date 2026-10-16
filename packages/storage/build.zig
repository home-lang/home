const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const storage_module = b.addModule("storage", .{
        .root_source_file = b.path("src/storage.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lib = b.addLibrary(.{
        .name = "storage",
        .linkage = .static,
        .root_module = storage_module,
    });
    b.installArtifact(lib);

    const unit_tests = b.addTest(.{ .root_module = storage_module });
    const memory_module = b.addModule("storage_memory", .{
        .root_source_file = b.path("src/memory.zig"),
        .target = target,
        .optimize = optimize,
    });
    const memory_tests = b.addTest(.{ .root_module = memory_module });
    const s3_module = b.addModule("storage_s3", .{
        .root_source_file = b.path("src/s3_driver.zig"),
        .target = target,
        .optimize = optimize,
    });
    const s3_tests = b.addTest(.{ .root_module = s3_module });
    const local_module = b.addModule("storage_local", .{
        .root_source_file = b.path("src/local.zig"),
        .target = target,
        .optimize = optimize,
    });
    const local_tests = b.addTest(.{ .root_module = local_module });

    const check_step = b.step("check", "Compile the shipped storage library and its tests");
    check_step.dependOn(&lib.step);
    check_step.dependOn(&unit_tests.step);
    check_step.dependOn(&memory_tests.step);
    check_step.dependOn(&s3_tests.step);
    check_step.dependOn(&local_tests.step);

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const run_memory_tests = b.addRunArtifact(memory_tests);
    const run_s3_tests = b.addRunArtifact(s3_tests);
    const run_local_tests = b.addRunArtifact(local_tests);
    const test_step = b.step("test", "Run storage tests");
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&run_memory_tests.step);
    test_step.dependOn(&run_s3_tests.step);
    test_step.dependOn(&run_local_tests.step);
}
