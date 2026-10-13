const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const intrinsics_module = b.addModule("intrinsics", .{
        .root_source_file = b.path("src/intrinsics.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lib = b.addLibrary(.{
        .name = "intrinsics",
        .linkage = .static,
        .root_module = intrinsics_module,
    });
    b.installArtifact(lib);

    const tests = b.addTest(.{ .root_module = intrinsics_module });

    const check_step = b.step("check", "Compile the shipped intrinsics library and its tests");
    check_step.dependOn(&lib.step);
    check_step.dependOn(&tests.step);

    const run_tests = b.addRunArtifact(tests);

    const test_step = b.step("test", "Run intrinsics tests");
    test_step.dependOn(&run_tests.step);
}
