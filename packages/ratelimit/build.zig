const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const ratelimit_module = b.addModule("ratelimit", .{
        .root_source_file = b.path("src/ratelimit.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lib = b.addLibrary(.{
        .name = "ratelimit",
        .linkage = .static,
        .root_module = ratelimit_module,
    });
    b.installArtifact(lib);

    const unit_tests = b.addTest(.{ .root_module = ratelimit_module });
    const public_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/ratelimit_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    public_tests.root_module.addImport("ratelimit", ratelimit_module);

    const check_step = b.step("check", "Compile the shipped rate-limit library and its tests");
    check_step.dependOn(&lib.step);
    check_step.dependOn(&unit_tests.step);
    check_step.dependOn(&public_tests.step);

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const run_public_tests = b.addRunArtifact(public_tests);
    const test_step = b.step("test", "Run rate limit tests");
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&run_public_tests.step);
}
