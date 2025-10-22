const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Zyte integration option
    const enable_zyte = b.option(bool, "zyte", "Enable Zyte integration") orelse false;
    const zyte_path = b.option([]const u8, "zyte-path", "Path to Zyte library") orelse
        "../zyte/packages/zig";

    // Create package modules
    const lexer_pkg = b.createModule(.{
        .root_source_file = b.path("packages/lexer/src/lexer.zig"),
        .target = target,
        .optimize = optimize,
    });

    const ast_pkg = b.createModule(.{
        .root_source_file = b.path("packages/ast/src/ast.zig"),
        .target = target,
        .optimize = optimize,
    });
    ast_pkg.addImport("lexer", lexer_pkg);

    const parser_pkg = b.createModule(.{
        .root_source_file = b.path("packages/parser/src/parser.zig"),
        .target = target,
        .optimize = optimize,
    });
    parser_pkg.addImport("lexer", lexer_pkg);
    parser_pkg.addImport("ast", ast_pkg);

    const diagnostics_pkg = b.createModule(.{
        .root_source_file = b.path("packages/diagnostics/src/diagnostics.zig"),
        .target = target,
        .optimize = optimize,
    });
    diagnostics_pkg.addImport("ast", ast_pkg);

    const types_pkg = b.createModule(.{
        .root_source_file = b.path("packages/types/src/type_system.zig"),
        .target = target,
        .optimize = optimize,
    });
    types_pkg.addImport("ast", ast_pkg);
    types_pkg.addImport("diagnostics", diagnostics_pkg);

    const interpreter_pkg = b.createModule(.{
        .root_source_file = b.path("packages/interpreter/src/interpreter.zig"),
        .target = target,
        .optimize = optimize,
    });
    interpreter_pkg.addImport("ast", ast_pkg);

    const codegen_pkg = b.createModule(.{
        .root_source_file = b.path("packages/codegen/src/native_codegen.zig"),
        .target = target,
        .optimize = optimize,
    });
    codegen_pkg.addImport("ast", ast_pkg);

    const formatter_pkg = b.createModule(.{
        .root_source_file = b.path("packages/formatter/src/formatter.zig"),
        .target = target,
        .optimize = optimize,
    });
    formatter_pkg.addImport("ast", ast_pkg);
    formatter_pkg.addImport("lexer", lexer_pkg);
    formatter_pkg.addImport("parser", parser_pkg);

    const pkg_manager_pkg = b.createModule(.{
        .root_source_file = b.path("packages/pkg/src/package_manager.zig"),
        .target = target,
        .optimize = optimize,
    });

    const queue_pkg = b.createModule(.{
        .root_source_file = b.path("packages/queue/src/queue.zig"),
        .target = target,
        .optimize = optimize,
    });

    const database_pkg = b.createModule(.{
        .root_source_file = b.path("packages/database/src/database.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Main executable
    const exe = b.addExecutable(.{
        .name = "ion",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // Add package imports to main executable
    exe.root_module.addImport("lexer", lexer_pkg);
    exe.root_module.addImport("ast", ast_pkg);
    exe.root_module.addImport("parser", parser_pkg);
    exe.root_module.addImport("types", types_pkg);
    exe.root_module.addImport("interpreter", interpreter_pkg);
    exe.root_module.addImport("codegen", codegen_pkg);
    exe.root_module.addImport("formatter", formatter_pkg);
    exe.root_module.addImport("diagnostics", diagnostics_pkg);
    exe.root_module.addImport("pkg_manager", pkg_manager_pkg);
    exe.root_module.addImport("queue", queue_pkg);
    exe.root_module.addImport("database", database_pkg);

    // Link Zyte if enabled
    if (enable_zyte) {
        std.debug.print("✅ Zyte integration enabled\n", .{});
        std.debug.print("   Path: {s}\n", .{zyte_path});

        // Add Zyte include path
        const zyte_src_path = b.fmt("{s}/src", .{zyte_path});
        exe.addIncludePath(b.path(zyte_src_path));

        // Link system libraries based on platform
        switch (target.result.os.tag) {
            .macos => {
                exe.linkFramework("Cocoa");
                exe.linkFramework("WebKit");
            },
            .linux => {
                exe.linkSystemLibrary("gtk-3");
                exe.linkSystemLibrary("webkit2gtk-4.0");
            },
            .windows => {
                exe.linkSystemLibrary("webview2");
            },
            else => {},
        }
    }

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
    ion_module.addImport("lexer", lexer_pkg);
    ion_module.addImport("ast", ast_pkg);
    ion_module.addImport("parser", parser_pkg);
    ion_module.addImport("types", types_pkg);
    ion_module.addImport("interpreter", interpreter_pkg);
    ion_module.addImport("codegen", codegen_pkg);

    // Create stdlib modules for tests and examples
    const http_router_module = b.createModule(.{
        .root_source_file = b.path("packages/stdlib/src/http_router.zig"),
        .target = target,
        .optimize = optimize,
    });

    const zyte_module = b.createModule(.{
        .root_source_file = b.path("packages/stdlib/src/zyte.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Lexer tests
    const lexer_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("packages/lexer/tests/lexer_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    lexer_tests.root_module.addImport("src_lexer", lexer_pkg);

    const run_lexer_tests = b.addRunArtifact(lexer_tests);

    // Parser tests
    const parser_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("packages/parser/tests/parser_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    parser_tests.root_module.addImport("ion", ion_module);

    const run_parser_tests = b.addRunArtifact(parser_tests);

    // HTTP Router tests
    const http_router_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("packages/stdlib/tests/http_router_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    http_router_tests.root_module.addImport("http_router", http_router_module);

    const run_http_router_tests = b.addRunArtifact(http_router_tests);

    // Zyte tests
    const zyte_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("packages/stdlib/tests/zyte_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    zyte_tests.root_module.addImport("zyte", zyte_module);

    const run_zyte_tests = b.addRunArtifact(zyte_tests);

    // Package Manager tests
    const package_manager_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("packages/pkg/tests/package_manager_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    package_manager_tests.root_module.addImport("package_manager", pkg_manager_pkg);

    const run_package_manager_tests = b.addRunArtifact(package_manager_tests);

    // Queue tests
    const queue_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("packages/queue/tests/queue_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    queue_tests.root_module.addImport("queue", queue_pkg);

    const run_queue_tests = b.addRunArtifact(queue_tests);

    // AST tests
    const ast_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("packages/ast/tests/ast_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    ast_tests.root_module.addImport("ast", ast_pkg);

    const run_ast_tests = b.addRunArtifact(ast_tests);

    // Diagnostics tests
    const diagnostics_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("packages/diagnostics/tests/diagnostics_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    diagnostics_tests.root_module.addImport("diagnostics", diagnostics_pkg);

    const run_diagnostics_tests = b.addRunArtifact(diagnostics_tests);

    // Interpreter tests
    const interpreter_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("packages/interpreter/tests/interpreter_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    interpreter_tests.root_module.addImport("interpreter", interpreter_pkg);

    const run_interpreter_tests = b.addRunArtifact(interpreter_tests);

    // Formatter tests
    const formatter_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("packages/formatter/tests/formatter_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    formatter_tests.root_module.addImport("formatter", formatter_pkg);

    const run_formatter_tests = b.addRunArtifact(formatter_tests);

    // Codegen tests
    const codegen_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("packages/codegen/tests/codegen_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    codegen_tests.root_module.addImport("codegen", codegen_pkg);

    const run_codegen_tests = b.addRunArtifact(codegen_tests);

    // Database tests
    const database_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("packages/database/tests/database_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    database_tests.root_module.addImport("database", database_pkg);
    database_tests.linkSystemLibrary("sqlite3");
    database_tests.linkLibC();

    const run_database_tests = b.addRunArtifact(database_tests);

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_lexer_tests.step);
    test_step.dependOn(&run_parser_tests.step);
    test_step.dependOn(&run_http_router_tests.step);
    test_step.dependOn(&run_zyte_tests.step);
    test_step.dependOn(&run_package_manager_tests.step);
    test_step.dependOn(&run_queue_tests.step);
    test_step.dependOn(&run_ast_tests.step);
    test_step.dependOn(&run_diagnostics_tests.step);
    test_step.dependOn(&run_interpreter_tests.step);
    test_step.dependOn(&run_formatter_tests.step);
    test_step.dependOn(&run_codegen_tests.step);
    test_step.dependOn(&run_database_tests.step);

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
        .root_source_file = b.path("packages/lexer/src/lexer.zig"),
    });
    lexer_bench.root_module.addAnonymousImport("token", .{
        .root_source_file = b.path("packages/lexer/src/token.zig"),
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

    // ═══════════════════════════════════════════════════════════════
    // Examples
    // ═══════════════════════════════════════════════════════════════

    // HTTP Router Example
    const http_router_example = b.addExecutable(.{
        .name = "http_router_example",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/http_router_example.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    http_router_example.root_module.addImport("http_router", http_router_module);
    b.installArtifact(http_router_example);

    const run_http_router_example = b.addRunArtifact(http_router_example);
    const http_router_example_step = b.step("example-router", "Run HTTP router example");
    http_router_example_step.dependOn(&run_http_router_example.step);

    // Zyte Example
    const zyte_example = b.addExecutable(.{
        .name = "zyte_example",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/zyte_example.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    zyte_example.root_module.addImport("zyte", zyte_module);
    zyte_example.root_module.addImport("http_router", http_router_module);
    b.installArtifact(zyte_example);

    const run_zyte_example = b.addRunArtifact(zyte_example);
    const zyte_example_step = b.step("example-zyte", "Run Zyte integration example");
    zyte_example_step.dependOn(&run_zyte_example.step);

    // Full-Stack Example (HTTP + Zyte)
    const fullstack_example = b.addExecutable(.{
        .name = "fullstack_example",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/full_stack_zyte.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    fullstack_example.root_module.addImport("http_router", http_router_module);
    fullstack_example.root_module.addImport("zyte", zyte_module);
    b.installArtifact(fullstack_example);

    const run_fullstack_example = b.addRunArtifact(fullstack_example);
    const fullstack_example_step = b.step("example-fullstack", "Run full-stack example (HTTP + Zyte)");
    fullstack_example_step.dependOn(&run_fullstack_example.step);

    // Queue Example
    const queue_example = b.addExecutable(.{
        .name = "queue_example",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/queue_example.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    queue_example.root_module.addImport("queue", queue_pkg);
    b.installArtifact(queue_example);

    const run_queue_example = b.addRunArtifact(queue_example);
    const queue_example_step = b.step("example-queue", "Run queue system example");
    queue_example_step.dependOn(&run_queue_example.step);

    // Database Example
    const database_example = b.addExecutable(.{
        .name = "database_example",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/database_example.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    database_example.root_module.addImport("database", database_pkg);
    database_example.linkSystemLibrary("sqlite3");
    database_example.linkLibC();
    b.installArtifact(database_example);

    const run_database_example = b.addRunArtifact(database_example);
    const database_example_step = b.step("example-database", "Run database example");
    database_example_step.dependOn(&run_database_example.step);

    // Run all examples
    const examples_step = b.step("examples", "Run all examples");
    examples_step.dependOn(&run_http_router_example.step);
    examples_step.dependOn(&run_zyte_example.step);
    examples_step.dependOn(&run_fullstack_example.step);
    examples_step.dependOn(&run_queue_example.step);
    examples_step.dependOn(&run_database_example.step);
}
