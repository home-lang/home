const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const cache_module = b.addModule("cache", .{
        .root_source_file = b.path("src/cache.zig"),
        .target = target,
        .optimize = optimize,
    });
    const incremental_module = b.addModule("incremental_cache", .{
        .root_source_file = b.path("src/incremental.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lib = b.addLibrary(.{
        .name = "cache",
        .linkage = .static,
        .root_module = cache_module,
    });
    b.installArtifact(lib);

    const unit_tests = b.addTest(.{ .root_module = cache_module });
    const incremental_tests = b.addTest(.{ .root_module = incremental_module });
    const public_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/cache_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    public_tests.root_module.addImport("cache", cache_module);
    public_tests.root_module.addImport("incremental_cache", incremental_module);
    public_tests.root_module.addImport("ir_cache", b.createModule(.{
        .root_source_file = b.path("src/ir_cache.zig"),
        .target = target,
        .optimize = optimize,
    }));

    const check_step = b.step("check", "Compile the shipped cache library and its tests");
    check_step.dependOn(&lib.step);
    check_step.dependOn(&unit_tests.step);
    check_step.dependOn(&incremental_tests.step);
    check_step.dependOn(&public_tests.step);

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const run_incremental_tests = b.addRunArtifact(incremental_tests);
    const run_public_tests = b.addRunArtifact(public_tests);
    const test_step = b.step("test", "Run cache tests");
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&run_incremental_tests.step);
    test_step.dependOn(&run_public_tests.step);
}
