const std = @import("std");

/// Helper function to create a package module with zig-test-framework imported
fn createPackage(
    b: *std.Build,
    path: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    test_framework: *std.Build.Module,
) *std.Build.Module {
    const module = b.createModule(.{
        .root_source_file = b.path(path),
        .target = target,
        .optimize = optimize,
    });
    // Add zig-test-framework to every package
    module.addImport("zig-test-framework", test_framework);
    return module;
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ========================================================================
    // Workspace-Level Dependencies
    // ========================================================================

    // Add zig-test-framework as a workspace-wide module
    // Available to all packages for testing and coverage
    const zig_test_framework = b.createModule(.{
        .root_source_file = .{ .cwd_relative = "/Users/chrisbreuer/Code/zig-test-framework/src/lib.zig" },
    });

    // Build options for conditional compilation
    const enable_craft = b.option(bool, "craft", "Enable Craft integration") orelse false;
    const craft_path = b.option([]const u8, "craft-path", "Path to Craft library") orelse
        "../craft/packages/zig";

    // Debugging and diagnostics
    const debug_logging = b.option(bool, "debug-log", "Enable verbose debug logging") orelse false;
    const memory_tracking = b.option(bool, "track-memory", "Enable memory allocation tracking") orelse false;

    // Performance options
    const enable_ir_cache = b.option(bool, "ir-cache", "Enable IR caching for faster recompilation") orelse true;
    const parallel_build = b.option(bool, "parallel", "Enable parallel compilation") orelse true;

    // Safety options
    const extra_safety = b.option(bool, "extra-safety", "Enable additional runtime safety checks") orelse (optimize == .Debug);

    // Profiling
    const enable_profiling = b.option(bool, "profile", "Enable profiling instrumentation") orelse false;

    // Create package modules using helper function (with zig-test-framework)
    const lexer_pkg = createPackage(b, "packages/lexer/src/lexer.zig", target, optimize, zig_test_framework);
    const ast_pkg = createPackage(b, "packages/ast/src/ast.zig", target, optimize, zig_test_framework);
    const parser_pkg = createPackage(b, "packages/parser/src/parser.zig", target, optimize, zig_test_framework);
    const diagnostics_pkg = createPackage(b, "packages/diagnostics/src/diagnostics.zig", target, optimize, zig_test_framework);
    const types_pkg = createPackage(b, "packages/types/src/type_system.zig", target, optimize, zig_test_framework);
    const interpreter_pkg = createPackage(b, "packages/interpreter/src/interpreter.zig", target, optimize, zig_test_framework);
    const comptime_pkg = createPackage(b, "packages/comptime/src/comptime.zig", target, optimize, zig_test_framework);
    const codegen_pkg = createPackage(b, "packages/codegen/src/codegen.zig", target, optimize, zig_test_framework);
    const config_pkg = createPackage(b, "packages/config/src/config.zig", target, optimize, zig_test_framework);
    const formatter_pkg = createPackage(b, "packages/formatter/src/formatter.zig", target, optimize, zig_test_framework);
    const linter_pkg = createPackage(b, "packages/linter/src/linter.zig", target, optimize, zig_test_framework);
    const macros_pkg = createPackage(b, "packages/macros/src/macro_system.zig", target, optimize, zig_test_framework);
    macros_pkg.addImport("ast", ast_pkg);
    const traits_pkg = createPackage(b, "packages/traits/src/traits.zig", target, optimize, zig_test_framework);
    const pkg_manager_pkg = createPackage(b, "packages/pkg/src/package_manager.zig", target, optimize, zig_test_framework);
    const queue_pkg = createPackage(b, "packages/queue/src/queue.zig", target, optimize, zig_test_framework);
    const database_pkg = createPackage(b, "packages/database/src/database.zig", target, optimize, zig_test_framework);
    const cache_pkg = createPackage(b, "packages/cache/src/ir_cache.zig", target, optimize, zig_test_framework);
    const threading_pkg = createPackage(b, "packages/threading/src/threading.zig", target, optimize, zig_test_framework);
    const memory_pkg = createPackage(b, "packages/memory/src/memory.zig", target, optimize, zig_test_framework);
    const intrinsics_pkg = createPackage(b, "packages/intrinsics/src/intrinsics.zig", target, optimize, zig_test_framework);
    const ffi_pkg = createPackage(b, "packages/ffi/src/ffi.zig", target, optimize, zig_test_framework);
    const math_pkg = createPackage(b, "packages/math/src/math.zig", target, optimize, zig_test_framework);
    const env_pkg = createPackage(b, "packages/env/src/env.zig", target, optimize, zig_test_framework);
    const syscall_pkg = createPackage(b, "packages/syscall/src/syscall.zig", target, optimize, zig_test_framework);
    const signal_pkg = createPackage(b, "packages/signal/src/signal.zig", target, optimize, zig_test_framework);
    const mac_pkg = createPackage(b, "packages/mac/src/mac.zig", target, optimize, zig_test_framework);
    const tpm_pkg = createPackage(b, "packages/tpm/src/tpm.zig", target, optimize, zig_test_framework);
    const modsign_pkg = createPackage(b, "packages/modsign/src/modsign.zig", target, optimize, zig_test_framework);
    const coredump_pkg = createPackage(b, "packages/coredump/src/coredump.zig", target, optimize, zig_test_framework);
    const syslog_pkg = createPackage(b, "packages/syslog/src/syslog.zig", target, optimize, zig_test_framework);
    const usb_pkg = createPackage(b, "packages/usb/src/usb.zig", target, optimize, zig_test_framework);
    const iommu_pkg = createPackage(b, "packages/iommu/src/iommu.zig", target, optimize, zig_test_framework);
    const timing_pkg = createPackage(b, "packages/timing/src/timing.zig", target, optimize, zig_test_framework);
    const bootloader_pkg = createPackage(b, "packages/bootloader/src/bootloader.zig", target, optimize, zig_test_framework);
    const ipv6_pkg = createPackage(b, "packages/ipv6/src/ipv6.zig", target, optimize, zig_test_framework);
    const dtb_pkg = createPackage(b, "packages/dtb/src/main.zig", target, optimize, zig_test_framework);
    const drivers_pkg = createPackage(b, "packages/drivers/src/main.zig", target, optimize, zig_test_framework);
    const variadic_pkg = createPackage(b, "packages/variadic/src/variadic.zig", target, optimize, zig_test_framework);
    const inline_pkg = createPackage(b, "packages/inline/src/inline.zig", target, optimize, zig_test_framework);
    const regalloc_pkg = createPackage(b, "packages/regalloc/src/regalloc.zig", target, optimize, zig_test_framework);
    const platform_pkg = createPackage(b, "packages/platform/src/platform.zig", target, optimize, zig_test_framework);
    const volatile_pkg = createPackage(b, "packages/volatile/src/volatile.zig", target, optimize, zig_test_framework);
    const pantry_pkg = createPackage(b, "packages/pantry/src/pantry.zig", target, optimize, zig_test_framework);
    const collections_pkg = createPackage(b, "packages/collections/src/collection.zig", target, optimize, zig_test_framework);
    const json_pkg = createPackage(b, "packages/json/src/json.zig", target, optimize, zig_test_framework);
    const file_pkg = createPackage(b, "packages/file/src/file.zig", target, optimize, zig_test_framework);
    const network_pkg = createPackage(b, "packages/network/src/network.zig", target, optimize, zig_test_framework);
    const http_pkg = createPackage(b, "packages/http/src/http.zig", target, optimize, zig_test_framework);

    // Graphics packages (for games)
    const opengl_pkg = createPackage(b, "packages/graphics/src/opengl.zig", target, optimize, zig_test_framework);
    opengl_pkg.addImport("ffi", ffi_pkg);
    const openal_pkg = createPackage(b, "packages/graphics/src/openal.zig", target, optimize, zig_test_framework);
    openal_pkg.addImport("ffi", ffi_pkg);
    const cocoa_pkg = createPackage(b, "packages/mac/src/cocoa.zig", target, optimize, zig_test_framework);
    cocoa_pkg.addImport("ffi", ffi_pkg);
    const input_pkg = createPackage(b, "packages/graphics/src/input.zig", target, optimize, zig_test_framework);
    input_pkg.addImport("cocoa", cocoa_pkg);
    const renderer_pkg = createPackage(b, "packages/graphics/src/renderer.zig", target, optimize, zig_test_framework);
    const particles_pkg = createPackage(b, "packages/graphics/src/particles.zig", target, optimize, zig_test_framework);
    const shaders_pkg = createPackage(b, "packages/graphics/src/shaders.zig", target, optimize, zig_test_framework);

    // Image processing package
    const image_pkg = createPackage(b, "packages/image/src/image.zig", target, optimize, zig_test_framework);

    // Game development packages (order matters for dependencies)
    const game_assets_pkg = createPackage(b, "packages/game/src/assets.zig", target, optimize, zig_test_framework);
    game_assets_pkg.addImport("image", image_pkg);
    const game_replay_pkg = createPackage(b, "packages/game/src/replay.zig", target, optimize, zig_test_framework);
    const game_mods_pkg = createPackage(b, "packages/game/src/mods.zig", target, optimize, zig_test_framework);
    const game_loop_pkg = createPackage(b, "packages/game/src/game_loop.zig", target, optimize, zig_test_framework);
    const game_ai_pkg = createPackage(b, "packages/game/src/ai.zig", target, optimize, zig_test_framework);
    const game_ecs_pkg = createPackage(b, "packages/game/src/ecs.zig", target, optimize, zig_test_framework);
    const game_network_pkg = createPackage(b, "packages/game/src/network.zig", target, optimize, zig_test_framework);

    // game_pkg depends on assets, replay, mods
    const game_pkg = createPackage(b, "packages/game/src/game.zig", target, optimize, zig_test_framework);
    game_pkg.addImport("game_assets", game_assets_pkg);
    game_pkg.addImport("game_replay", game_replay_pkg);
    game_pkg.addImport("game_mods", game_mods_pkg);

    // pathfinding depends on game (for Vec2)
    const game_pathfinding_pkg = createPackage(b, "packages/game/src/pathfinding.zig", target, optimize, zig_test_framework);
    game_pathfinding_pkg.addImport("game", game_pkg);

    // Setup dependencies between packages
    ast_pkg.addImport("lexer", lexer_pkg);
    parser_pkg.addImport("lexer", lexer_pkg);
    parser_pkg.addImport("ast", ast_pkg);
    diagnostics_pkg.addImport("ast", ast_pkg);
    parser_pkg.addImport("diagnostics", diagnostics_pkg);
    types_pkg.addImport("ast", ast_pkg);
    types_pkg.addImport("diagnostics", diagnostics_pkg);
    types_pkg.addImport("traits", traits_pkg);
    traits_pkg.addImport("ast", ast_pkg);
    interpreter_pkg.addImport("ast", ast_pkg);
    comptime_pkg.addImport("ast", ast_pkg);
    types_pkg.addImport("comptime", comptime_pkg);
    codegen_pkg.addImport("ast", ast_pkg);
    codegen_pkg.addImport("lexer", lexer_pkg);
    codegen_pkg.addImport("parser", parser_pkg);
    codegen_pkg.addImport("types", types_pkg);
    codegen_pkg.addImport("comptime", comptime_pkg);
    formatter_pkg.addImport("ast", ast_pkg);
    formatter_pkg.addImport("lexer", lexer_pkg);
    formatter_pkg.addImport("parser", parser_pkg);
    linter_pkg.addImport("ast", ast_pkg);
    linter_pkg.addImport("lexer", lexer_pkg);
    linter_pkg.addImport("parser", parser_pkg);
    linter_pkg.addImport("config", config_pkg);
    memory_pkg.addImport("threading", threading_pkg);

    // Main executable
    const exe = b.addExecutable(.{
        .name = "home",
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
    exe.root_module.addImport("linter", linter_pkg);
    exe.root_module.addImport("macros", macros_pkg);
    exe.root_module.addImport("traits", traits_pkg);
    exe.root_module.addImport("diagnostics", diagnostics_pkg);
    exe.root_module.addImport("pkg_manager", pkg_manager_pkg);
    exe.root_module.addImport("queue", queue_pkg);
    exe.root_module.addImport("database", database_pkg);
    exe.root_module.addImport("ir_cache", cache_pkg);
    exe.root_module.addImport("collections", collections_pkg);
    exe.root_module.addImport("json", json_pkg);
    exe.root_module.addImport("file", file_pkg);
    exe.root_module.addImport("network", network_pkg);
    exe.root_module.addImport("http", http_pkg);

    // Create build options module for conditional compilation
    const build_options = b.addOptions();
    build_options.addOption(bool, "enable_craft", enable_craft);
    build_options.addOption(bool, "debug_logging", debug_logging);
    build_options.addOption(bool, "memory_tracking", memory_tracking);
    build_options.addOption(bool, "enable_ir_cache", enable_ir_cache);
    build_options.addOption(bool, "parallel_build", parallel_build);
    build_options.addOption(bool, "extra_safety", extra_safety);
    build_options.addOption(bool, "enable_profiling", enable_profiling);

    // Add build options to executable
    exe.root_module.addImport("build_options", build_options.createModule());

    // Link Craft if enabled
    if (enable_craft) {
        std.debug.print("✅ Craft integration enabled\n", .{});
        std.debug.print("   Path: {s}\n", .{craft_path});

        // Add Craft include path
        const craft_src_path = b.fmt("{s}/src", .{craft_path});
        exe.addIncludePath(b.path(craft_src_path));

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

    // Create 'hm' symlink as shorthand for 'home'
    const install_hm_symlink = b.addInstallBinFile(exe.getEmittedBin(), "hm");
    install_hm_symlink.step.dependOn(&exe.step);
    b.getInstallStep().dependOn(&install_hm_symlink.step);

    // Create 'homecheck' alias for testing (runs 'home test' automatically)
    const install_homecheck_symlink = b.addInstallBinFile(exe.getEmittedBin(), "homecheck");
    install_homecheck_symlink.step.dependOn(&exe.step);
    b.getInstallStep().dependOn(&install_homecheck_symlink.step);

    // Run command
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the Home compiler");
    run_step.dependOn(&run_cmd.step);

    // Test suite - use home module as root
    const home_module = b.createModule(.{
        .root_source_file = b.path("src/home.zig"),
        .target = target,
        .optimize = optimize,
    });
    home_module.addImport("zig-test-framework", zig_test_framework);
    home_module.addImport("lexer", lexer_pkg);
    home_module.addImport("ast", ast_pkg);
    home_module.addImport("parser", parser_pkg);
    home_module.addImport("types", types_pkg);
    home_module.addImport("interpreter", interpreter_pkg);
    home_module.addImport("codegen", codegen_pkg);

    // Create basics modules for tests and examples
    const http_router_module = b.createModule(.{
        .root_source_file = b.path("packages/basics/src/http_router.zig"),
        .target = target,
        .optimize = optimize,
    });
    http_router_module.addImport("zig-test-framework", zig_test_framework);

    const craft_module = b.createModule(.{
        .root_source_file = b.path("packages/basics/src/craft.zig"),
        .target = target,
        .optimize = optimize,
    });
    craft_module.addImport("zig-test-framework", zig_test_framework);

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
    parser_tests.root_module.addImport("home", home_module);
    parser_tests.root_module.addImport("zig-test-framework", zig_test_framework);

    const run_parser_tests = b.addRunArtifact(parser_tests);

    // HTTP Router tests
    const http_router_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("packages/basics/tests/http_router_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    http_router_tests.root_module.addImport("http_router", http_router_module);
    http_router_tests.root_module.addImport("zig-test-framework", zig_test_framework);

    const run_http_router_tests = b.addRunArtifact(http_router_tests);

    // Craft tests
    const craft_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("packages/basics/tests/craft_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    craft_tests.root_module.addImport("craft", craft_module);
    craft_tests.root_module.addImport("zig-test-framework", zig_test_framework);

    const run_craft_tests = b.addRunArtifact(craft_tests);

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

    // Threading tests
    const threading_tests = b.addTest(.{
        .root_module = threading_pkg,
    });

    const run_threading_tests = b.addRunArtifact(threading_tests);

    // Memory allocator tests
    const memory_tests = b.addTest(.{
        .root_module = memory_pkg,
    });

    const run_memory_tests = b.addRunArtifact(memory_tests);

    // Intrinsics tests
    const intrinsics_tests = b.addTest(.{
        .root_module = intrinsics_pkg,
    });

    const run_intrinsics_tests = b.addRunArtifact(intrinsics_tests);

    // FFI tests
    const ffi_tests = b.addTest(.{
        .root_module = ffi_pkg,
    });
    ffi_tests.linkLibC();

    const run_ffi_tests = b.addRunArtifact(ffi_tests);

    // Math tests
    const math_tests = b.addTest(.{
        .root_module = math_pkg,
    });

    const run_math_tests = b.addRunArtifact(math_tests);

    // Env tests
    const env_tests = b.addTest(.{
        .root_module = env_pkg,
    });

    const run_env_tests = b.addRunArtifact(env_tests);

    // Syscall tests
    const syscall_tests = b.addTest(.{
        .root_module = syscall_pkg,
    });

    const run_syscall_tests = b.addRunArtifact(syscall_tests);

    // Signal tests
    const signal_tests = b.addTest(.{
        .root_module = signal_pkg,
    });

    const run_signal_tests = b.addRunArtifact(signal_tests);

    // MAC tests
    const mac_tests = b.addTest(.{
        .root_module = mac_pkg,
    });

    const run_mac_tests = b.addRunArtifact(mac_tests);

    // TPM tests
    const tpm_tests = b.addTest(.{
        .root_module = tpm_pkg,
    });

    const run_tpm_tests = b.addRunArtifact(tpm_tests);

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_lexer_tests.step);
    test_step.dependOn(&run_parser_tests.step);
    test_step.dependOn(&run_http_router_tests.step);
    test_step.dependOn(&run_craft_tests.step);
    test_step.dependOn(&run_package_manager_tests.step);
    test_step.dependOn(&run_queue_tests.step);
    test_step.dependOn(&run_ast_tests.step);
    test_step.dependOn(&run_diagnostics_tests.step);
    test_step.dependOn(&run_interpreter_tests.step);
    test_step.dependOn(&run_formatter_tests.step);
    test_step.dependOn(&run_codegen_tests.step);
    test_step.dependOn(&run_database_tests.step);
    test_step.dependOn(&run_threading_tests.step);
    test_step.dependOn(&run_memory_tests.step);
    test_step.dependOn(&run_intrinsics_tests.step);
    test_step.dependOn(&run_ffi_tests.step);
    test_step.dependOn(&run_math_tests.step);
    test_step.dependOn(&run_env_tests.step);
    test_step.dependOn(&run_syscall_tests.step);
    test_step.dependOn(&run_signal_tests.step);
    test_step.dependOn(&run_mac_tests.step);
    test_step.dependOn(&run_tpm_tests.step);

    // Modsign tests
    const modsign_tests = b.addTest(.{ .root_module = modsign_pkg });
    const run_modsign_tests = b.addRunArtifact(modsign_tests);
    test_step.dependOn(&run_modsign_tests.step);

    // Coredump tests
    const coredump_tests = b.addTest(.{ .root_module = coredump_pkg });
    const run_coredump_tests = b.addRunArtifact(coredump_tests);
    test_step.dependOn(&run_coredump_tests.step);

    // Syslog tests
    const syslog_tests = b.addTest(.{ .root_module = syslog_pkg });
    const run_syslog_tests = b.addRunArtifact(syslog_tests);
    test_step.dependOn(&run_syslog_tests.step);

    // USB security tests
    const usb_tests = b.addTest(.{ .root_module = usb_pkg });
    const run_usb_tests = b.addRunArtifact(usb_tests);
    test_step.dependOn(&run_usb_tests.step);

    // IOMMU tests
    const iommu_tests = b.addTest(.{ .root_module = iommu_pkg });
    const run_iommu_tests = b.addRunArtifact(iommu_tests);
    test_step.dependOn(&run_iommu_tests.step);

    // Timing attack mitigation tests
    const timing_tests = b.addTest(.{ .root_module = timing_pkg });
    const run_timing_tests = b.addRunArtifact(timing_tests);
    test_step.dependOn(&run_timing_tests.step);

    // Bootloader tests
    const bootloader_tests = b.addTest(.{ .root_module = bootloader_pkg });
    const run_bootloader_tests = b.addRunArtifact(bootloader_tests);
    test_step.dependOn(&run_bootloader_tests.step);

    // IPv6 networking tests
    const ipv6_tests = b.addTest(.{ .root_module = ipv6_pkg });
    const run_ipv6_tests = b.addRunArtifact(ipv6_tests);
    test_step.dependOn(&run_ipv6_tests.step);

    // Device Tree Binary tests
    const dtb_tests = b.addTest(.{ .root_module = dtb_pkg });
    const run_dtb_tests = b.addRunArtifact(dtb_tests);
    test_step.dependOn(&run_dtb_tests.step);

    // Hardware drivers tests
    const drivers_tests = b.addTest(.{ .root_module = drivers_pkg });
    const run_drivers_tests = b.addRunArtifact(drivers_tests);
    test_step.dependOn(&run_drivers_tests.step);

    // Variadic functions tests
    const variadic_tests = b.addTest(.{ .root_module = variadic_pkg });
    const run_variadic_tests = b.addRunArtifact(variadic_tests);
    test_step.dependOn(&run_variadic_tests.step);

    // Inline functions tests
    const inline_tests = b.addTest(.{ .root_module = inline_pkg });
    const run_inline_tests = b.addRunArtifact(inline_tests);
    test_step.dependOn(&run_inline_tests.step);

    // Register allocation tests
    const regalloc_tests = b.addTest(.{ .root_module = regalloc_pkg });
    const run_regalloc_tests = b.addRunArtifact(regalloc_tests);
    test_step.dependOn(&run_regalloc_tests.step);

    // Platform-specific code blocks tests
    const platform_tests = b.addTest(.{ .root_module = platform_pkg });
    const run_platform_tests = b.addRunArtifact(platform_tests);
    test_step.dependOn(&run_platform_tests.step);

    // Volatile operations tests
    const volatile_tests = b.addTest(.{ .root_module = volatile_pkg });
    const run_volatile_tests = b.addRunArtifact(volatile_tests);
    test_step.dependOn(&run_volatile_tests.step);

    // Pantry tests
    const pantry_tests = b.addTest(.{ .root_module = pantry_pkg });
    const run_pantry_tests = b.addRunArtifact(pantry_tests);
    test_step.dependOn(&run_pantry_tests.step);

    // Test zig-test-framework integration
    const framework_integration_mod = b.createModule(.{
        .root_source_file = b.path("packages/build/test_framework_integration.zig"),
        .target = target,
        .optimize = optimize,
    });
    framework_integration_mod.addImport("zig-test-framework", zig_test_framework);

    const framework_integration_tests = b.addTest(.{ .root_module = framework_integration_mod });
    const run_framework_integration_tests = b.addRunArtifact(framework_integration_tests);

    const framework_test_step = b.step("test-framework", "Test zig-test-framework integration");
    framework_test_step.dependOn(&run_framework_integration_tests.step);

    // Coverage test runner executable
    const coverage_runner = b.addExecutable(.{
        .name = "coverage-runner",
        .root_module = b.createModule(.{
            .root_source_file = b.path("packages/build/test_with_coverage.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    coverage_runner.root_module.addImport("zig-test-framework", zig_test_framework);
    b.installArtifact(coverage_runner);

    const run_coverage_runner = b.addRunArtifact(coverage_runner);
    const coverage_step = b.step("coverage", "Run coverage test runner");
    coverage_step.dependOn(&run_coverage_runner.step);

    // Parallel test runner with caching and benchmarking
    // TODO: Fix ArrayList compilation issue in Zig 0.15.1
    // const test_runner_pkg = createPackage(b, "packages/testing/src/test_runner.zig", target, optimize);

    // const test_runner_exe = b.addExecutable(.{
    //     .name = "ion-test",
    //     .root_module = b.createModule(.{
    //         .root_source_file = b.path("packages/testing/src/test_cli.zig"),
    //         .target = target,
    //         .optimize = optimize,
    //     }),
    // });

    // test_runner_exe.root_module.addImport("test_runner", test_runner_pkg);

    // b.installArtifact(test_runner_exe);

    // const run_test_runner = b.addRunArtifact(test_runner_exe);
    // if (b.args) |args| {
    //     run_test_runner.addArgs(args);
    // }

    // const test_parallel_step = b.step("test-parallel", "Run all tests in parallel with caching");
    // test_parallel_step.dependOn(&run_test_runner.step);

    // Parallel build demo
    const parallel_build_demo = b.addExecutable(.{
        .name = "parallel-build-demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("packages/build/src/parallel_build_demo.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    b.installArtifact(parallel_build_demo);

    const run_parallel_build = b.addRunArtifact(parallel_build_demo);
    if (b.args) |args| {
        run_parallel_build.addArgs(args);
    }

    const parallel_build_step = b.step("parallel-build", "Run parallel build demo");
    parallel_build_step.dependOn(&run_parallel_build.step);

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

    // Parser benchmark suite - use home module
    const parser_bench = b.addExecutable(.{
        .name = "parser_bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/parser_bench.zig"),
            .target = target,
            .optimize = .ReleaseFast,
        }),
    });

    parser_bench.root_module.addImport("home", home_module);

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

    // Craft Example
    const craft_example = b.addExecutable(.{
        .name = "craft_example",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/craft_example.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    craft_example.root_module.addImport("craft", craft_module);
    craft_example.root_module.addImport("http_router", http_router_module);
    b.installArtifact(craft_example);

    const run_craft_example = b.addRunArtifact(craft_example);
    const craft_example_step = b.step("example-craft", "Run Craft integration example");
    craft_example_step.dependOn(&run_craft_example.step);

    // Full-Stack Example (HTTP + Craft)
    const fullstack_example = b.addExecutable(.{
        .name = "fullstack_example",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/full_stack_craft.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    fullstack_example.root_module.addImport("http_router", http_router_module);
    fullstack_example.root_module.addImport("craft", craft_module);
    b.installArtifact(fullstack_example);

    const run_fullstack_example = b.addRunArtifact(fullstack_example);
    const fullstack_example_step = b.step("example-fullstack", "Run full-stack example (HTTP + Craft)");
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

    // Generals Engine Example (C&C Generals recreation)
    const generals_example = b.addExecutable(.{
        .name = "generals",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/generals_engine_example.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    // Add graphics packages
    generals_example.root_module.addImport("opengl", opengl_pkg);
    generals_example.root_module.addImport("openal", openal_pkg);
    generals_example.root_module.addImport("input", input_pkg);
    generals_example.root_module.addImport("cocoa", cocoa_pkg);
    generals_example.root_module.addImport("renderer", renderer_pkg);
    generals_example.root_module.addImport("particles", particles_pkg);
    generals_example.root_module.addImport("shaders", shaders_pkg);
    // Add game development packages
    generals_example.root_module.addImport("game", game_pkg);
    generals_example.root_module.addImport("game_loop", game_loop_pkg);
    generals_example.root_module.addImport("game_assets", game_assets_pkg);
    generals_example.root_module.addImport("game_ai", game_ai_pkg);
    generals_example.root_module.addImport("game_ecs", game_ecs_pkg);
    generals_example.root_module.addImport("game_pathfinding", game_pathfinding_pkg);
    generals_example.root_module.addImport("game_network", game_network_pkg);
    generals_example.root_module.addImport("game_replay", game_replay_pkg);
    generals_example.root_module.addImport("game_mods", game_mods_pkg);
    // Link macOS frameworks
    generals_example.linkFramework("Cocoa");
    generals_example.linkFramework("OpenGL");
    generals_example.linkFramework("OpenAL");
    generals_example.linkFramework("AudioToolbox");
    generals_example.linkLibC();
    b.installArtifact(generals_example);

    const run_generals_example = b.addRunArtifact(generals_example);
    const generals_example_step = b.step("generals", "Run C&C Generals engine example");
    generals_example_step.dependOn(&run_generals_example.step);

    // Run all examples
    const examples_step = b.step("examples", "Run all examples");
    examples_step.dependOn(&run_http_router_example.step);
    examples_step.dependOn(&run_craft_example.step);
    examples_step.dependOn(&run_fullstack_example.step);
    examples_step.dependOn(&run_queue_example.step);
    examples_step.dependOn(&run_database_example.step);
    examples_step.dependOn(&run_generals_example.step);

    // ═══════════════════════════════════════════════════════════════
    // Additional Build Modes
    // ═══════════════════════════════════════════════════════════════

    // Debug build (with debug symbols and runtime safety)
    const debug_exe = b.addExecutable(.{
        .name = "home-debug",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = .Debug,
        }),
    });
    debug_exe.root_module.addImport("lexer", lexer_pkg);
    debug_exe.root_module.addImport("ast", ast_pkg);
    debug_exe.root_module.addImport("parser", parser_pkg);
    debug_exe.root_module.addImport("types", types_pkg);
    debug_exe.root_module.addImport("interpreter", interpreter_pkg);
    debug_exe.root_module.addImport("codegen", codegen_pkg);
    debug_exe.root_module.addImport("formatter", formatter_pkg);
    debug_exe.root_module.addImport("linter", linter_pkg);
    debug_exe.root_module.addImport("macros", macros_pkg);
    debug_exe.root_module.addImport("traits", traits_pkg);
    debug_exe.root_module.addImport("diagnostics", diagnostics_pkg);
    debug_exe.root_module.addImport("pkg_manager", pkg_manager_pkg);
    debug_exe.root_module.addImport("queue", queue_pkg);
    debug_exe.root_module.addImport("database", database_pkg);
    debug_exe.root_module.addImport("ir_cache", cache_pkg);
    debug_exe.root_module.addImport("collections", collections_pkg);
    debug_exe.root_module.addImport("json", json_pkg);
    debug_exe.root_module.addImport("file", file_pkg);
    debug_exe.root_module.addImport("network", network_pkg);
    debug_exe.root_module.addImport("http", http_pkg);
    debug_exe.root_module.addImport("build_options", build_options.createModule());

    const install_debug = b.addInstallArtifact(debug_exe, .{});
    const debug_step = b.step("debug", "Build Home compiler in Debug mode (with safety checks)");
    debug_step.dependOn(&install_debug.step);

    // Release-safe build (optimized but with runtime safety)
    const release_safe_exe = b.addExecutable(.{
        .name = "home-release-safe",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = .ReleaseSafe,
        }),
    });
    release_safe_exe.root_module.addImport("lexer", lexer_pkg);
    release_safe_exe.root_module.addImport("ast", ast_pkg);
    release_safe_exe.root_module.addImport("parser", parser_pkg);
    release_safe_exe.root_module.addImport("types", types_pkg);
    release_safe_exe.root_module.addImport("interpreter", interpreter_pkg);
    release_safe_exe.root_module.addImport("codegen", codegen_pkg);
    release_safe_exe.root_module.addImport("formatter", formatter_pkg);
    release_safe_exe.root_module.addImport("linter", linter_pkg);
    release_safe_exe.root_module.addImport("traits", traits_pkg);
    release_safe_exe.root_module.addImport("diagnostics", diagnostics_pkg);
    release_safe_exe.root_module.addImport("pkg_manager", pkg_manager_pkg);
    release_safe_exe.root_module.addImport("queue", queue_pkg);
    release_safe_exe.root_module.addImport("database", database_pkg);
    release_safe_exe.root_module.addImport("ir_cache", cache_pkg);
    release_safe_exe.root_module.addImport("collections", collections_pkg);
    release_safe_exe.root_module.addImport("json", json_pkg);
    release_safe_exe.root_module.addImport("file", file_pkg);
    release_safe_exe.root_module.addImport("network", network_pkg);
    release_safe_exe.root_module.addImport("http", http_pkg);
    release_safe_exe.root_module.addImport("build_options", build_options.createModule());

    const install_release_safe = b.addInstallArtifact(release_safe_exe, .{});
    const release_safe_step = b.step("release-safe", "Build Home compiler in ReleaseSafe mode (optimized with safety)");
    release_safe_step.dependOn(&install_release_safe.step);

    // Release-small build (optimize for size)
    const release_small_exe = b.addExecutable(.{
        .name = "home-release-small",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = .ReleaseSmall,
        }),
    });
    release_small_exe.root_module.addImport("lexer", lexer_pkg);
    release_small_exe.root_module.addImport("ast", ast_pkg);
    release_small_exe.root_module.addImport("parser", parser_pkg);
    release_small_exe.root_module.addImport("types", types_pkg);
    release_small_exe.root_module.addImport("interpreter", interpreter_pkg);
    release_small_exe.root_module.addImport("codegen", codegen_pkg);
    release_small_exe.root_module.addImport("formatter", formatter_pkg);
    release_small_exe.root_module.addImport("linter", linter_pkg);
    release_small_exe.root_module.addImport("traits", traits_pkg);
    release_small_exe.root_module.addImport("diagnostics", diagnostics_pkg);
    release_small_exe.root_module.addImport("pkg_manager", pkg_manager_pkg);
    release_small_exe.root_module.addImport("queue", queue_pkg);
    release_small_exe.root_module.addImport("database", database_pkg);
    release_small_exe.root_module.addImport("ir_cache", cache_pkg);
    release_small_exe.root_module.addImport("collections", collections_pkg);
    release_small_exe.root_module.addImport("json", json_pkg);
    release_small_exe.root_module.addImport("file", file_pkg);
    release_small_exe.root_module.addImport("network", network_pkg);
    release_small_exe.root_module.addImport("http", http_pkg);
    release_small_exe.root_module.addImport("build_options", build_options.createModule());

    const install_release_small = b.addInstallArtifact(release_small_exe, .{});
    const release_small_step = b.step("release-small", "Build Home compiler in ReleaseSmall mode (optimized for size)");
    release_small_step.dependOn(&install_release_small.step);

    // Documentation generation
    const docs_install = b.addInstallDirectory(.{
        .source_dir = exe.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });

    const docs_step = b.step("docs", "Generate documentation for Home");
    docs_step.dependOn(&docs_install.step);
}
