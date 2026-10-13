const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const serialization = b.addModule("serialization", .{
        .root_source_file = b.path("src/serialization.zig"),
        .target = target,
        .optimize = optimize,
    });

    const library = b.addLibrary(.{
        .name = "serialization",
        .linkage = .static,
        .root_module = serialization,
    });
    b.installArtifact(library);

    const module_tests = b.addTest(.{ .root_module = serialization });
    const public_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/serialization_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    public_tests.root_module.addImport("serialization", serialization);

    const check_step = b.step("check", "Compile the shipped module and public API tests");
    check_step.dependOn(&library.step);
    check_step.dependOn(&module_tests.step);
    check_step.dependOn(&public_tests.step);

    const test_step = b.step("test", "Run serialization tests");
    test_step.dependOn(&b.addRunArtifact(module_tests).step);
    test_step.dependOn(&b.addRunArtifact(public_tests).step);

    const install_docs = b.addInstallDirectory(.{
        .source_dir = public_tests.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs/serialization",
    });
    const docs_step = b.step("docs", "Generate serialization documentation");
    docs_step.dependOn(&install_docs.step);
}
