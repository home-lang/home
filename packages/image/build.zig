const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Main image library module
    const image_module = b.addModule("image", .{
        .root_source_file = b.path("src/image.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Static library
    const lib = b.addStaticLibrary(.{
        .name = "image",
        .root_source_file = b.path("src/image.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Enable SIMD optimizations for release builds
    if (optimize != .Debug) {
        lib.root_module.addCMacro("ENABLE_SIMD", "1");
    }

    b.installArtifact(lib);

    // Shared library
    const shared_lib = b.addSharedLibrary(.{
        .name = "image",
        .root_source_file = b.path("src/image.zig"),
        .target = target,
        .optimize = optimize,
    });

    if (optimize != .Debug) {
        shared_lib.root_module.addCMacro("ENABLE_SIMD", "1");
    }

    b.installArtifact(shared_lib);

    // Unit tests
    const unit_tests = b.addTest(.{
        .root_source_file = b.path("src/image.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // Format tests
    const format_tests = [_]struct { name: []const u8, file: []const u8 }{
        .{ .name = "png", .file = "src/formats/png.zig" },
        .{ .name = "jpeg", .file = "src/formats/jpeg.zig" },
        .{ .name = "gif", .file = "src/formats/gif.zig" },
        .{ .name = "bmp", .file = "src/formats/bmp.zig" },
        .{ .name = "webp", .file = "src/formats/webp.zig" },
        .{ .name = "tiff", .file = "src/formats/tiff.zig" },
        .{ .name = "tga", .file = "src/formats/tga.zig" },
        .{ .name = "ppm", .file = "src/formats/ppm.zig" },
        .{ .name = "qoi", .file = "src/formats/qoi.zig" },
        .{ .name = "hdr", .file = "src/formats/hdr.zig" },
    };

    const format_test_step = b.step("test-formats", "Run format-specific tests");
    for (format_tests) |t| {
        const format_test = b.addTest(.{
            .root_source_file = b.path(t.file),
            .target = target,
            .optimize = optimize,
        });
        const run_format_test = b.addRunArtifact(format_test);
        format_test_step.dependOn(&run_format_test.step);
    }

    // Operations tests
    const ops_tests = [_]struct { name: []const u8, file: []const u8 }{
        .{ .name = "resize", .file = "src/ops/resize.zig" },
        .{ .name = "crop", .file = "src/ops/crop.zig" },
        .{ .name = "transform", .file = "src/ops/transform.zig" },
        .{ .name = "color", .file = "src/ops/color.zig" },
        .{ .name = "filter", .file = "src/ops/filter.zig" },
    };

    const ops_test_step = b.step("test-ops", "Run operations tests");
    for (ops_tests) |t| {
        const ops_test = b.addTest(.{
            .root_source_file = b.path(t.file),
            .target = target,
            .optimize = optimize,
        });
        const run_ops_test = b.addRunArtifact(ops_test);
        ops_test_step.dependOn(&run_ops_test.step);
    }

    // Benchmark executable
    const bench = b.addExecutable(.{
        .name = "image-bench",
        .root_source_file = b.path("src/bench.zig"),
        .target = target,
        .optimize = .ReleaseFast,
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
            .root_source_file = b.path(example_path),
            .target = target,
            .optimize = optimize,
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

    // Clean step
    const clean_step = b.step("clean", "Remove build artifacts");
    clean_step.dependOn(&b.addRemoveDirTree(b.path("zig-out")).step);
    clean_step.dependOn(&b.addRemoveDirTree(b.path(".zig-cache")).step);

    // All tests
    const all_tests_step = b.step("test-all", "Run all tests");
    all_tests_step.dependOn(test_step);
    all_tests_step.dependOn(format_test_step);
    all_tests_step.dependOn(ops_test_step);
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
