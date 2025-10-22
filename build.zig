const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Main executable
    const exe = b.addExecutable(.{
        .name = "ion",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(exe);

    // Run command
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the Ion compiler");
    run_step.dependOn(&run_cmd.step);

    // Test suite - use ion module as root
    const ion_module = b.createModule(.{
        .root_source_file = b.path("src/ion.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lexer_module = b.createModule(.{
        .root_source_file = b.path("src/lexer/lexer.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Lexer tests
    const lexer_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/lexer_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    lexer_tests.root_module.addImport("src_lexer", lexer_module);

    const run_lexer_tests = b.addRunArtifact(lexer_tests);

    // Parser tests
    const parser_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/parser_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    parser_tests.root_module.addImport("ion", ion_module);

    const run_parser_tests = b.addRunArtifact(parser_tests);

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_lexer_tests.step);
    test_step.dependOn(&run_parser_tests.step);

    // Lexer benchmark suite
    const lexer_bench = b.addExecutable(.{
        .name = "lexer_bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/lexer_bench.zig"),
            .target = target,
            .optimize = .ReleaseFast,
        }),
    });

    lexer_bench.root_module.addAnonymousImport("lexer", .{
        .root_source_file = b.path("src/lexer/lexer.zig"),
    });
    lexer_bench.root_module.addAnonymousImport("token", .{
        .root_source_file = b.path("src/lexer/token.zig"),
    });

    b.installArtifact(lexer_bench);

    const run_lexer_bench = b.addRunArtifact(lexer_bench);

    // Parser benchmark suite - use ion module
    const parser_bench = b.addExecutable(.{
        .name = "parser_bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/parser_bench.zig"),
            .target = target,
            .optimize = .ReleaseFast,
        }),
    });

    parser_bench.root_module.addImport("ion", ion_module);

    b.installArtifact(parser_bench);

    const run_parser_bench = b.addRunArtifact(parser_bench);

    const bench_step = b.step("bench", "Run all benchmarks");
    bench_step.dependOn(&run_lexer_bench.step);
    bench_step.dependOn(&run_parser_bench.step);
}
