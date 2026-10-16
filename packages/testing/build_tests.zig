const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const vitest = b.createModule(.{
        .root_source_file = b.path("src/vitest.zig"),
        .target = target,
        .optimize = optimize,
    });

    const suites = [_][]const u8{
        "tests/test_matchers.zig",
        "tests/test_framework.zig",
        "tests/test_mocks.zig",
        "tests/test_snapshots.zig",
        "tests/vitest_test.zig",
    };

    const test_step = b.step("test", "Run the standalone Vitest-compatible suite");
    for (suites) |source_path| {
        const tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(source_path),
                .target = target,
                .optimize = optimize,
            }),
        });
        tests.root_module.addImport("vitest", vitest);
        const run_tests = b.addRunArtifact(tests);
        test_step.dependOn(&run_tests.step);
    }
}
