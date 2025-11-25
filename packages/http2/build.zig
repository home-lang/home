const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ========================================================================
    // HTTP/2 Client Module
    // ========================================================================

    const client_module = b.addModule("client", .{
        .root_source_file = b.path("src/client.zig"),
        .target = target,
        .optimize = optimize,
    });

    // ========================================================================
    // HPACK Module
    // ========================================================================

    const hpack_module = b.addModule("hpack", .{
        .root_source_file = b.path("src/hpack.zig"),
        .target = target,
        .optimize = optimize,
    });

    // ========================================================================
    // Frame Module
    // ========================================================================

    const frame_module = b.addModule("frame", .{
        .root_source_file = b.path("src/frame.zig"),
        .target = target,
        .optimize = optimize,
    });

    // ========================================================================
    // HTTP/2 Main Module
    // ========================================================================

    const http2_module = b.addModule("http2", .{
        .root_source_file = b.path("src/http2.zig"),
        .target = target,
        .optimize = optimize,
    });
    http2_module.addImport("client", client_module);
    http2_module.addImport("hpack", hpack_module);
    http2_module.addImport("frame", frame_module);

    // ========================================================================
    // Tests
    // ========================================================================

    const http2_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/http2_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    http2_tests.root_module.addImport("http2", http2_module);
    http2_tests.root_module.addImport("client", client_module);
    http2_tests.root_module.addImport("hpack", hpack_module);

    const run_http2_tests = b.addRunArtifact(http2_tests);

    const test_step = b.step("test", "Run HTTP/2 tests");
    test_step.dependOn(&run_http2_tests.step);

    // ========================================================================
    // Examples
    // ========================================================================

    // Simple GET example
    const get_example = b.addExecutable(.{
        .name = "http2_get",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/get_example.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    get_example.root_module.addImport("http2", http2_module);
    b.installArtifact(get_example);

    const run_get_example = b.addRunArtifact(get_example);
    const get_example_step = b.step("example-get", "Run HTTP/2 GET example");
    get_example_step.dependOn(&run_get_example.step);

    // POST example
    const post_example = b.addExecutable(.{
        .name = "http2_post",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/post_example.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    post_example.root_module.addImport("http2", http2_module);
    b.installArtifact(post_example);

    const run_post_example = b.addRunArtifact(post_example);
    const post_example_step = b.step("example-post", "Run HTTP/2 POST example");
    post_example_step.dependOn(&run_post_example.step);

    // Run all examples
    const examples_step = b.step("examples", "Run all HTTP/2 examples");
    examples_step.dependOn(&run_get_example.step);
    examples_step.dependOn(&run_post_example.step);

    // ========================================================================
    // Documentation
    // ========================================================================

    const docs_install = b.addInstallDirectory(.{
        .source_dir = http2_tests.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs/http2",
    });

    const docs_step = b.step("docs", "Generate HTTP/2 documentation");
    docs_step.dependOn(&docs_install.step);
}
