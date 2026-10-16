const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const build_module = b.addModule("home-build", .{
        .root_source_file = b.path("src/parallel_build.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const lib = b.addLibrary(.{
        .name = "home-build",
        .linkage = .static,
        .root_module = build_module,
    });
    b.installArtifact(lib);

    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/build_tests.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    const watcher_module = b.addModule("file_watcher", .{
        .root_source_file = b.path("src/file_watcher.zig"),
        .target = target,
        .optimize = optimize,
    });
    const watcher_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/file_watcher_test.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    watcher_tests.root_module.addImport("file_watcher", watcher_module);

    const check_step = b.step("check", "Compile the shipped build library and active tests");
    check_step.dependOn(&lib.step);
    check_step.dependOn(&unit_tests.step);
    check_step.dependOn(&watcher_tests.step);

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run active build-system tests");
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&b.addRunArtifact(watcher_tests).step);
}
