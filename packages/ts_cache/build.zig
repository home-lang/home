const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const cache_module = b.addModule("ts_cache", .{
        .root_source_file = b.path("src/ts_cache.zig"),
        .target = target,
        .optimize = optimize,
    });
    const lib = b.addLibrary(.{
        .name = "home-ts-cache",
        .linkage = .static,
        .root_module = cache_module,
    });
    b.installArtifact(lib);

    const unit_tests = b.addTest(.{ .root_module = cache_module });
    const public_module = b.createModule(.{
        .root_source_file = b.path("tests/ts_cache_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    public_module.addImport("ts_cache", cache_module);
    const public_tests = b.addTest(.{ .root_module = public_module });

    const check_step = b.step("check", "Compile the shipped cache and both test roots");
    check_step.dependOn(&lib.step);
    check_step.dependOn(&unit_tests.step);
    check_step.dependOn(&public_tests.step);

    const test_step = b.step("test", "Run cache unit and public API tests");
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);
    test_step.dependOn(&b.addRunArtifact(public_tests).step);
}
