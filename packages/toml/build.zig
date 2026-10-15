const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const toml = b.addModule("toml", .{
        .root_source_file = b.path("src/toml.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lib = b.addLibrary(.{
        .name = "home-toml",
        .linkage = .static,
        .root_module = toml,
    });
    b.installArtifact(lib);

    const unit_tests = b.addTest(.{ .root_module = toml });
    const run_unit_tests = b.addRunArtifact(unit_tests);

    const check_step = b.step("check", "Compile the TOML library and tests");
    check_step.dependOn(&lib.step);
    check_step.dependOn(&unit_tests.step);

    const test_step = b.step("test", "Run TOML tests");
    test_step.dependOn(&run_unit_tests.step);
}
