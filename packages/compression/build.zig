const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const compression = b.addModule("compression", .{
        .root_source_file = b.path("src/compression.zig"),
        .target = target,
        .optimize = optimize,
    });

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/compression_tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    tests.root_module.addImport("compression", compression);

    const run_tests = b.addRunArtifact(tests);
    const check_step = b.step("check", "Compile compression tests without running them");
    check_step.dependOn(&tests.step);

    const test_step = b.step("test", "Run compression tests");
    test_step.dependOn(&run_tests.step);

    const install_docs = b.addInstallDirectory(.{
        .source_dir = tests.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs/compression",
    });
    const docs_step = b.step("docs", "Generate compression documentation");
    docs_step.dependOn(&install_docs.step);
}
