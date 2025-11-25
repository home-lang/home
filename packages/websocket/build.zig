const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ========================================================================
    // WebSocket Module
    // ========================================================================

    const websocket_module = b.addModule("websocket", .{
        .root_source_file = b.path("src/websocket.zig"),
        .target = target,
        .optimize = optimize,
    });

    // ========================================================================
    // Tests
    // ========================================================================

    const websocket_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/websocket_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    websocket_tests.root_module.addImport("websocket", websocket_module);

    const run_websocket_tests = b.addRunArtifact(websocket_tests);

    const test_step = b.step("test", "Run WebSocket tests");
    test_step.dependOn(&run_websocket_tests.step);

    // ========================================================================
    // Examples
    // ========================================================================

    // Echo client example
    const echo_example = b.addExecutable(.{
        .name = "websocket_echo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/echo_client.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    echo_example.root_module.addImport("websocket", websocket_module);
    b.installArtifact(echo_example);

    const run_echo_example = b.addRunArtifact(echo_example);
    const echo_example_step = b.step("example-echo", "Run WebSocket echo client example");
    echo_example_step.dependOn(&run_echo_example.step);

    // Chat client example
    const chat_example = b.addExecutable(.{
        .name = "websocket_chat",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/chat_client.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    chat_example.root_module.addImport("websocket", websocket_module);
    b.installArtifact(chat_example);

    const run_chat_example = b.addRunArtifact(chat_example);
    const chat_example_step = b.step("example-chat", "Run WebSocket chat client example");
    chat_example_step.dependOn(&run_chat_example.step);

    // Run all examples
    const examples_step = b.step("examples", "Run all WebSocket examples");
    examples_step.dependOn(&run_echo_example.step);
    examples_step.dependOn(&run_chat_example.step);

    // ========================================================================
    // Documentation
    // ========================================================================

    const docs_install = b.addInstallDirectory(.{
        .source_dir = websocket_tests.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs/websocket",
    });

    const docs_step = b.step("docs", "Generate WebSocket documentation");
    docs_step.dependOn(&docs_install.step);
}
