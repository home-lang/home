const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Main image library module
    const image_module = b.addModule("image", .{
        .root_source_file = b.path("src/image.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    image_module.linkSystemLibrary("z", .{});

    if (optimize != .debug) {
        image_module.addCMacro("ENABLE_SIMD", "1");
    }

    // Static library
    const lib = b.addLibrary(.{
        .name = "image",
        .linkage = .static,
        .root_module = image_module,
    });
    b.installArtifact(lib);

    // Shared library
    const shared_lib = b.addLibrary(.{
        .name = "image",
        .linkage = .dynamic,
        .root_module = image_module,
    });
    b.installArtifact(shared_lib);

    // Unit tests
    const unit_tests = b.addTest(.{ .root_module = image_module });

    const check_step = b.step("check", "Compile the shipped image libraries and all tests");
    check_step.dependOn(&lib.step);
    check_step.dependOn(&shared_lib.step);
    check_step.dependOn(&unit_tests.step);

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // Format tests
    const format_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/formats_tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    check_step.dependOn(&format_tests.step);
    const run_format_tests = b.addRunArtifact(format_tests);
    const format_test_step = b.step("test-formats", "Run format-specific tests");
    format_test_step.dependOn(&run_format_tests.step);

    // Metadata tests
    const metadata_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/metadata_tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    check_step.dependOn(&metadata_tests.step);
    const run_metadata_tests = b.addRunArtifact(metadata_tests);
    const metadata_test_step = b.step("test-metadata", "Run metadata parser and writer tests");
    metadata_test_step.dependOn(&run_metadata_tests.step);

    // Operations tests
    const ops_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/ops_tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    check_step.dependOn(&ops_tests.step);
    const run_ops_tests = b.addRunArtifact(ops_tests);
    const ops_test_step = b.step("test-ops", "Run operations tests");
    ops_test_step.dependOn(&run_ops_tests.step);

    // File I/O and batch-processing tests
    const io_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/io_tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    check_step.dependOn(&io_tests.step);
    const run_io_tests = b.addRunArtifact(io_tests);
    const io_test_step = b.step("test-io", "Run file I/O and batch-processing tests");
    io_test_step.dependOn(&run_io_tests.step);

    // Benchmark executable
    const bench = b.addExecutable(.{
        .name = "image-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bench.zig"),
            .target = target,
            .optimize = .fast,
        }),
    });

    bench.root_module.addImport("image", image_module);

    const install_bench = b.addInstallArtifact(bench, .{});
    const bench_step = b.step("bench", "Build benchmark executable");
    bench_step.dependOn(&install_bench.step);

    // Example executables
    const examples = [_][]const u8{
        "basic_usage",
        "format_conversion",
        "image_processing",
        "animation",
        "metadata",
    };

    const examples_step = b.step("examples", "Build example executables");
    for (examples) |example| {
        const example_path = b.fmt("examples/{s}.zig", .{example});
        const exe = b.addExecutable(.{
            .name = example,
            .root_module = b.createModule(.{
                .root_source_file = b.path(example_path),
                .target = target,
                .optimize = optimize,
            }),
        });
        exe.root_module.addImport("image", image_module);
        const install_exe = b.addInstallArtifact(exe, .{});
        examples_step.dependOn(&install_exe.step);
    }

    // Documentation
    const docs = b.addInstallDirectory(.{
        .source_dir = lib.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });

    const docs_step = b.step("docs", "Generate documentation");
    docs_step.dependOn(&docs.step);

    // All tests
    const all_tests_step = b.step("test-all", "Run all tests");
    all_tests_step.dependOn(test_step);
    all_tests_step.dependOn(format_test_step);
    all_tests_step.dependOn(metadata_test_step);
    all_tests_step.dependOn(ops_test_step);
    all_tests_step.dependOn(io_test_step);
}

/// Package configuration for use as a dependency
pub const Package = struct {
    image: *std.Build.Module,

    pub fn init(b: *std.Build, args: struct {
        target: std.Build.ResolvedTarget,
        optimize: std.builtin.OptimizeMode,
    }) Package {
        return .{
            .image = b.addModule("image", .{
                .root_source_file = b.path("src/image.zig"),
                .target = args.target,
                .optimize = args.optimize,
            }),
        };
    }

    pub fn addTo(self: Package, compile: *std.Build.Step.Compile) void {
        compile.root_module.addImport("image", self.image);
    }
};
