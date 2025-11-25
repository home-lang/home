const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ========================================================================
    // MessagePack Module
    // ========================================================================

    const msgpack_module = b.addModule("msgpack", .{
        .root_source_file = b.path("src/msgpack.zig"),
        .target = target,
        .optimize = optimize,
    });

    // ========================================================================
    // Protocol Buffers Module
    // ========================================================================

    const protobuf_module = b.addModule("protobuf", .{
        .root_source_file = b.path("src/protobuf.zig"),
        .target = target,
        .optimize = optimize,
    });

    // ========================================================================
    // Serialization Main Module
    // ========================================================================

    const serialization_module = b.addModule("serialization", .{
        .root_source_file = b.path("src/serialization.zig"),
        .target = target,
        .optimize = optimize,
    });
    serialization_module.addImport("msgpack", msgpack_module);
    serialization_module.addImport("protobuf", protobuf_module);

    // ========================================================================
    // Tests
    // ========================================================================

    // MessagePack tests
    const msgpack_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/msgpack_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    msgpack_tests.root_module.addImport("msgpack", msgpack_module);

    const run_msgpack_tests = b.addRunArtifact(msgpack_tests);

    // Protocol Buffers tests
    const protobuf_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/protobuf_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    protobuf_tests.root_module.addImport("protobuf", protobuf_module);

    const run_protobuf_tests = b.addRunArtifact(protobuf_tests);

    const test_step = b.step("test", "Run serialization tests");
    test_step.dependOn(&run_msgpack_tests.step);
    test_step.dependOn(&run_protobuf_tests.step);

    // ========================================================================
    // Examples
    // ========================================================================

    // MessagePack example
    const msgpack_example = b.addExecutable(.{
        .name = "msgpack_example",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/msgpack_example.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    msgpack_example.root_module.addImport("msgpack", msgpack_module);
    b.installArtifact(msgpack_example);

    const run_msgpack_example = b.addRunArtifact(msgpack_example);
    const msgpack_example_step = b.step("example-msgpack", "Run MessagePack example");
    msgpack_example_step.dependOn(&run_msgpack_example.step);

    // Protocol Buffers example
    const protobuf_example = b.addExecutable(.{
        .name = "protobuf_example",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/protobuf_example.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    protobuf_example.root_module.addImport("protobuf", protobuf_module);
    b.installArtifact(protobuf_example);

    const run_protobuf_example = b.addRunArtifact(protobuf_example);
    const protobuf_example_step = b.step("example-protobuf", "Run Protocol Buffers example");
    protobuf_example_step.dependOn(&run_protobuf_example.step);

    // Code generation example
    const codegen_example = b.addExecutable(.{
        .name = "protobuf_codegen",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/codegen_example.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    codegen_example.root_module.addImport("protobuf", protobuf_module);
    b.installArtifact(codegen_example);

    const run_codegen_example = b.addRunArtifact(codegen_example);
    const codegen_example_step = b.step("example-codegen", "Run code generation example");
    codegen_example_step.dependOn(&run_codegen_example.step);

    // Run all examples
    const examples_step = b.step("examples", "Run all serialization examples");
    examples_step.dependOn(&run_msgpack_example.step);
    examples_step.dependOn(&run_protobuf_example.step);
    examples_step.dependOn(&run_codegen_example.step);

    // ========================================================================
    // Documentation
    // ========================================================================

    const docs_install = b.addInstallDirectory(.{
        .source_dir = msgpack_tests.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs/serialization",
    });

    const docs_step = b.step("docs", "Generate serialization documentation");
    docs_step.dependOn(&docs_install.step);
}
