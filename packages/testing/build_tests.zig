const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Test executables
    const tests = [_]struct {
        name: []const u8,
        path: []const u8,
    }{
        .{ .name = "test_matchers", .path = "tests/test_matchers.zig" },
        .{ .name = "test_framework", .path = "tests/test_framework.zig" },
        .{ .name = "test_mocks", .path = "tests/test_mocks.zig" },
        .{ .name = "test_snapshots", .path = "tests/test_snapshots.zig" },
    };

    // Build each test executable
    for (tests) |test_info| {
        const exe = b.addExecutable(.{
            .name = test_info.name,
            .root_source_file = b.path(test_info.path),
            .target = target,
            .optimize = optimize,
        });

        b.installArtifact(exe);

        // Add run step for this test
        const run_cmd = b.addRunArtifact(exe);
        run_cmd.step.dependOn(b.getInstallStep());

        const run_step = b.step(test_info.name, b.fmt("Run {s}", .{test_info.name}));
        run_step.dependOn(&run_cmd.step);
    }

    // Master test runner
    const run_all = b.addExecutable(.{
        .name = "run_all_tests",
        .root_source_file = b.path("tests/run_all_tests.zig"),
        .target = target,
        .optimize = optimize,
    });

    b.installArtifact(run_all);

    const run_all_cmd = b.addRunArtifact(run_all);
    run_all_cmd.step.dependOn(b.getInstallStep());

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_all_cmd.step);
}
