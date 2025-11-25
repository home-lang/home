const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ========================================================================
    // GZIP Module
    // ========================================================================

    const gzip_module = b.addModule("gzip", .{
        .root_source_file = b.path("src/gzip.zig"),
        .target = target,
        .optimize = optimize,
    });

    // ========================================================================
    // Zstandard Module
    // ========================================================================

    const zstd_module = b.addModule("zstd", .{
        .root_source_file = b.path("src/zstd.zig"),
        .target = target,
        .optimize = optimize,
    });

    // ========================================================================
    // Compression Main Module
    // ========================================================================

    const compression_module = b.addModule("compression", .{
        .root_source_file = b.path("src/compression.zig"),
        .target = target,
        .optimize = optimize,
    });
    compression_module.addImport("gzip", gzip_module);
    compression_module.addImport("zstd", zstd_module);

    // ========================================================================
    // Tests
    // ========================================================================

    // GZIP tests
    const gzip_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/gzip_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    gzip_tests.root_module.addImport("gzip", gzip_module);

    const run_gzip_tests = b.addRunArtifact(gzip_tests);

    // Zstandard tests
    const zstd_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/zstd_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    zstd_tests.root_module.addImport("zstd", zstd_module);

    const run_zstd_tests = b.addRunArtifact(zstd_tests);

    const test_step = b.step("test", "Run compression tests");
    test_step.dependOn(&run_gzip_tests.step);
    test_step.dependOn(&run_zstd_tests.step);

    // ========================================================================
    // Examples
    // ========================================================================

    // GZIP example
    const gzip_example = b.addExecutable(.{
        .name = "gzip_example",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/gzip_example.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    gzip_example.root_module.addImport("gzip", gzip_module);
    b.installArtifact(gzip_example);

    const run_gzip_example = b.addRunArtifact(gzip_example);
    const gzip_example_step = b.step("example-gzip", "Run GZIP example");
    gzip_example_step.dependOn(&run_gzip_example.step);

    // Zstandard example
    const zstd_example = b.addExecutable(.{
        .name = "zstd_example",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/zstd_example.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    zstd_example.root_module.addImport("zstd", zstd_module);
    b.installArtifact(zstd_example);

    const run_zstd_example = b.addRunArtifact(zstd_example);
    const zstd_example_step = b.step("example-zstd", "Run Zstandard example");
    zstd_example_step.dependOn(&run_zstd_example.step);

    // Benchmark
    const benchmark = b.addExecutable(.{
        .name = "compression_benchmark",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/benchmark.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    benchmark.root_module.addImport("compression", compression_module);
    b.installArtifact(benchmark);

    const run_benchmark = b.addRunArtifact(benchmark);
    const benchmark_step = b.step("benchmark", "Run compression benchmarks");
    benchmark_step.dependOn(&run_benchmark.step);

    // Run all examples
    const examples_step = b.step("examples", "Run all compression examples");
    examples_step.dependOn(&run_gzip_example.step);
    examples_step.dependOn(&run_zstd_example.step);

    // ========================================================================
    // Documentation
    // ========================================================================

    const docs_install = b.addInstallDirectory(.{
        .source_dir = gzip_tests.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs/compression",
    });

    const docs_step = b.step("docs", "Generate compression documentation");
    docs_step.dependOn(&docs_install.step);
}
