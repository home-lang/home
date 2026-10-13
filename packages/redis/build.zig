const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const redis_module = b.addModule("redis", .{
        .root_source_file = b.path("src/redis.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lib = b.addLibrary(.{
        .name = "redis",
        .linkage = .static,
        .root_module = redis_module,
    });

    b.installArtifact(lib);

    const lib_unit_tests = b.addTest(.{ .root_module = redis_module });
    const public_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/redis_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    public_tests.root_module.addImport("redis", redis_module);

    const check_step = b.step("check", "Compile the shipped Redis library and its tests");
    check_step.dependOn(&lib.step);
    check_step.dependOn(&lib_unit_tests.step);
    check_step.dependOn(&public_tests.step);

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);
    const run_public_tests = b.addRunArtifact(public_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
    test_step.dependOn(&run_public_tests.step);
}
