const std = @import("std");

/// Compile flags for the vendored SQLite amalgamation (Bun's feature set:
/// fast, small, threadsafe). Applied only when statically compiling sqlite3.c
/// on Linux/Windows/cross targets; macOS links the system libsqlite3 instead.
const sqlite_amalgamation_flags = [_][]const u8{
    "-DSQLITE_THREADSAFE=1",
    "-DSQLITE_ENABLE_COLUMN_METADATA=1",
    "-DSQLITE_MAX_VARIABLE_NUMBER=250000",
    "-DSQLITE_ENABLE_RTREE=1",
    "-DSQLITE_ENABLE_FTS3=1",
    "-DSQLITE_ENABLE_FTS3_PARENTHESIS=1",
    "-DSQLITE_ENABLE_FTS5=1",
    "-DSQLITE_ENABLE_JSON1=1",
    "-DSQLITE_ENABLE_MATH_FUNCTIONS=1",
    "-DSQLITE_ENABLE_UPDATE_DELETE_LIMIT=1",
    "-DSQLITE_UDL_CAPABLE_PARSER=1",
    "-DSQLITE_DQS=0",
    "-Wno-incompatible-pointer-types-discards-qualifiers",
};

/// Resolve the active Xcode macOS SDK path. Panics if it can't be found -
/// only called from macOS-only branches.
fn macosSdkPath(b: *std.Build, target: std.Build.ResolvedTarget) []const u8 {
    return std.zig.system.darwin.getSdk(b.allocator, b.graph.io, &target.result) orelse
        std.debug.panic("could not locate macOS SDK via xcrun; is Xcode installed?", .{});
}

/// Helper function to create a package module with optional zig-test-framework
fn createPackage(
    b: *std.Build,
    path: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    test_framework: ?*std.Build.Module,
) *std.Build.Module {
    const module = b.createModule(.{
        .root_source_file = b.path(path),
        .target = target,
        .optimize = optimize,
    });
    // Add zig-test-framework if available
    if (test_framework) |tf| {
        module.addImport("zig-test-framework", tf);
    }
    return module;
}

fn testMatches(filter: ?[]const u8, name: []const u8) bool {
    if (filter) |needle| {
        return needle.len == 0 or std.mem.indexOf(u8, name, needle) != null;
    }
    return true;
}

fn dependOnTest(
    test_step: *std.Build.Step,
    run_step: *std.Build.Step,
    filter: ?[]const u8,
    name: []const u8,
) void {
    if (testMatches(filter, name)) {
        test_step.dependOn(run_step);
    }
}

// Native JSC link: instead of Apple's system JavaScriptCore.framework (which
// lacks Bun's custom `Bun__*`/`JSC__*` bindings), link Bun's own built C++
// objects + the vendored WebKit static libs (+ Rust lib + macOS frameworks).
// Paths point at a local Bun release build (`bun scripts/build.ts --profile=release`).
// Gated: if the artifacts are absent we fall back to the system framework so the
// non-native build still works. Only exercised once the home_rt module compiles.
const bun_obj_root = "/Users/chrisbreuer/Code/bun/build/release/obj";
const bun_webkit_lib = "/Users/chrisbreuer/.bun/build-cache/webkit-5488984d20e0dbfe-arm64/lib";
const link_bun_rust_archive = false;

const native_vendor_roots = [_][]const u8{
    "vendor/boringssl/",
    "vendor/cares/",
    "vendor/hdrhistogram/",
    "vendor/highway/",
    "vendor/libarchive/",
    "vendor/libdeflate/",
    "vendor/libjpeg-turbo/",
    "vendor/libspng/",
    "vendor/libwebp/",
    "vendor/lsqpack/",
    "vendor/lshpack/",
    "vendor/lsquic/",
    "vendor/picohttpparser/",
    "vendor/tinycc/",
    "vendor/zstd/",
};

const native_skip_paths = [_][]const u8{
    "src/jsc/bindings/uv-posix-stubs.c.o",
    "src/jsc/bindings/napi.cpp.o",
};

fn shouldLinkBunObject(path: []const u8) bool {
    for (native_skip_paths) |skip| {
        if (std.mem.eql(u8, path, skip)) return false;
    }

    if (std.mem.startsWith(u8, path, "vendor/")) {
        for (native_vendor_roots) |root| {
            if (std.mem.startsWith(u8, path, root)) return true;
        }
        return false;
    }

    return true;
}

fn linkBunNative(b: *std.Build, m: *std.Build.Module, target: std.Build.ResolvedTarget) void {
    m.linkSystemLibrary("c++", .{});
    m.linkSystemLibrary("uv", .{});
    if (target.result.os.tag == .macos) {
        m.linkSystemLibrary("icucore", .{});
    }

    // Fork std: filesystem moved to `std.Io.Dir` (io-parameterized).
    const io = std.Io.Threaded.global_single_threaded.io();

    // If Bun's objects aren't present, fall back to the system framework.
    var dir = std.Io.Dir.openDirAbsolute(io, bun_obj_root, .{ .iterate = true }) catch {
        if (target.result.os.tag == .macos) m.linkFramework("JavaScriptCore", .{});
        std.debug.print("warn: Bun native objects not found at {s}; using system JavaScriptCore\n", .{bun_obj_root});
        return;
    };
    defer dir.close(io);

    var walker = dir.walk(b.allocator) catch return;
    defer walker.deinit();
    while (walker.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".o")) continue;
        if (!shouldLinkBunObject(entry.path)) continue;
        m.addObjectFile(.{ .cwd_relative = b.fmt("{s}/{s}", .{ bun_obj_root, entry.path }) });
    }

    m.addCSourceFile(.{
        .file = b.path("packages/runtime/src/native/napi_weak_home_dups.cpp"),
        .flags = &.{ "-std=c++20", "-Wno-unused-parameter" },
        .language = .cpp,
    });

    // WebKit static libs (JavaScriptCore engine + WTF + bmalloc).
    m.addObjectFile(.{ .cwd_relative = b.fmt("{s}/libJavaScriptCore.a", .{bun_webkit_lib}) });
    m.addObjectFile(.{ .cwd_relative = b.fmt("{s}/libWTF.a", .{bun_webkit_lib}) });
    m.addObjectFile(.{ .cwd_relative = b.fmt("{s}/libbmalloc.a", .{bun_webkit_lib}) });

    // Bun's Rust static lib (bun_css/clap/etc.) is kept opt-in during the Home
    // runtime port because it also exports generated Bun ABI symbols now owned
    // by Home's ZigGeneratedClasses module.
    if (link_bun_rust_archive) {
        m.addObjectFile(.{ .cwd_relative = ".native/libbun_rust_no_main.a" });
    }

    if (target.result.os.tag == .macos) {
        for ([_][]const u8{
            "CoreFoundation", "Security",     "SystemConfiguration",
            "IOKit",          "CoreServices", "Foundation",
            "CoreText",       "CoreGraphics", "Metal",
        }) |fw| m.linkFramework(fw, .{});
    }
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ========================================================================
    // Workspace-Level Dependencies
    // ========================================================================

    // Try to find zig-test-framework (optional)
    // If not found, packages will build without test framework support
    const test_framework_path = b.option(
        []const u8,
        "test-framework-path",
        "Path to zig-test-framework (optional)",
    );
    const test_filter = b.option(
        []const u8,
        "filter",
        "Only run umbrella test artifacts whose package name contains this substring",
    );
    const ts_conformance_test_filter = b.option(
        []const u8,
        "ts-conformance-test-filter",
        "Only compile/run ts_conformance tests whose name contains this substring",
    );

    const zig_test_framework: ?*std.Build.Module = if (test_framework_path) |path|
        b.createModule(.{
            .root_source_file = .{ .cwd_relative = path },
        })
    else
        null;

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

    // Coverage and sanitizers
    const enable_coverage = b.option(bool, "coverage", "Enable code coverage instrumentation") orelse false;
    const enable_sanitize_address = b.option(bool, "sanitize-address", "Enable AddressSanitizer for memory error detection") orelse false;
    const enable_sanitize_undefined = b.option(bool, "sanitize-undefined", "Enable UndefinedBehaviorSanitizer") orelse false;
    const enable_sanitize_thread = b.option(bool, "sanitize-thread", "Enable ThreadSanitizer for data race detection") orelse false;

    // Link JavaScriptCore-backed runtime and bootstrap tests whenever the
    // target platform has a native framework we can faithfully exercise.
    // Keep the option override for constrained hosts and cross targets.
    const enable_jsc = b.option(bool, "enable_jsc", "Link JavaScriptCore into home_rt/home_test tests (default true on macOS)") orelse (target.result.os.tag == .macos);

    // Faithful macro support. Defaults to the upstream-faithful `true`.
    // Setting `-Denable_macros=false` gates `FeatureFlags.is_macro_enabled`
    // so the transpile path can comptime-eliminate the macro -> resolver ->
    // package-manager -> network -> event-loop -> bake cone.
    const enable_macros = b.option(bool, "enable_macros", "Enable JS/TS macro support (default true; the faithful default)") orelse true;

    // Create package modules using helper function (with zig-test-framework)
    const lexer_pkg = createPackage(b, "packages/lexer/src/lexer.zig", target, optimize, zig_test_framework);
    const ast_pkg = createPackage(b, "packages/ast/src/ast.zig", target, optimize, zig_test_framework);
    const parser_pkg = createPackage(b, "packages/parser/src/parser.zig", target, optimize, zig_test_framework);
    const diagnostics_pkg = createPackage(b, "packages/diagnostics/src/diagnostics.zig", target, optimize, zig_test_framework);
    const types_pkg = createPackage(b, "packages/types/src/type_system.zig", target, optimize, zig_test_framework);
    const interpreter_pkg = createPackage(b, "packages/interpreter/src/interpreter.zig", target, optimize, zig_test_framework);
    const comptime_pkg = createPackage(b, "packages/comptime/src/comptime.zig", target, optimize, zig_test_framework);
    const generics_pkg = createPackage(b, "packages/generics/src/generic_system.zig", target, optimize, zig_test_framework);
    const codegen_pkg = createPackage(b, "packages/codegen/src/codegen.zig", target, optimize, zig_test_framework);
    const compiler_pkg = createPackage(b, "packages/compiler/src/borrow_check_pass.zig", target, optimize, zig_test_framework);
    const optimizer_pkg = createPackage(b, "packages/optimizer/src/pass_manager.zig", target, optimize, zig_test_framework);
    const config_pkg = createPackage(b, "packages/config/src/config.zig", target, optimize, zig_test_framework);
    const formatter_pkg = createPackage(b, "packages/formatter/src/formatter.zig", target, optimize, zig_test_framework);
    const linter_pkg = createPackage(b, "packages/linter/src/linter.zig", target, optimize, zig_test_framework);
    const macros_pkg = createPackage(b, "packages/macros/src/macro_system.zig", target, optimize, zig_test_framework);
    macros_pkg.addImport("ast", ast_pkg);
    const traits_pkg = createPackage(b, "packages/traits/src/traits.zig", target, optimize, zig_test_framework);
    const pkg_manager_pkg = createPackage(b, "packages/pkg/src/package_manager.zig", target, optimize, zig_test_framework);
    const queue_pkg = createPackage(b, "packages/queue/src/queue.zig", target, optimize, zig_test_framework);
    const database_pkg = createPackage(b, "packages/database/src/database.zig", target, optimize, zig_test_framework);
    {
        // SQLite strategy mirrors Bun: macOS uses the system libsqlite3; Linux,
        // Windows and any cross-compile statically link the vendored amalgamation.
        // We translate-c the *vendored* header for ALL targets, so no system
        // <sqlite3.h> needs to be on the host include path (Zig ships the libc
        // headers translate-c needs, so this works when cross-compiling too).
        const sqlite_c = b.addTranslateC(.{
            .root_source_file = b.path("packages/database/vendor/sqlite3.h"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        database_pkg.addImport("c", sqlite_c.createModule());
        database_pkg.link_libc = true;
        if (target.result.os.tag == .macos) {
            database_pkg.linkSystemLibrary("sqlite3", .{});
        } else {
            database_pkg.addCSourceFile(.{
                .file = b.path("packages/database/vendor/sqlite3.c"),
                .flags = &sqlite_amalgamation_flags,
            });
        }
    }
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

    // TS-parity Phase 0 infrastructure packages (see docs/TS_PARITY_PLAN.md).
    // These have no dependencies on the rest of the codebase; they form the
    // shared substrate that the future TS frontend, HIR, query DB, and
    // performance engineering work builds on top of.
    const arena_pkg = createPackage(b, "packages/arena/src/arena.zig", target, optimize, zig_test_framework);
    const string_interner_pkg = createPackage(b, "packages/string_interner/src/string_interner.zig", target, optimize, zig_test_framework);
    const hir_pkg = createPackage(b, "packages/hir/src/hir.zig", target, optimize, zig_test_framework);
    hir_pkg.addImport("string_interner", string_interner_pkg);
    const query_pkg = createPackage(b, "packages/query/src/query.zig", target, optimize, zig_test_framework);
    // TS-parity Phase 0.7 — extracted parser modules. Tests run as their
    // own root so they're picked up by `zig build test`.
    const parsers_precedence_pkg = createPackage(b, "packages/parser/src/parsers/precedence.zig", target, optimize, zig_test_framework);
    parsers_precedence_pkg.addImport("lexer", lexer_pkg);
    // TS-parity Phase 0.8 — extracted codegen submodules.
    const native_layouts_pkg = createPackage(b, "packages/codegen/src/native/layouts.zig", target, optimize, zig_test_framework);
    native_layouts_pkg.addImport("ast", ast_pkg);

    // TS-parity Phase 1 — TypeScript frontend packages.
    const ts_lexer_pkg = createPackage(b, "packages/ts_lexer/src/ts_lexer.zig", target, optimize, zig_test_framework);
    const ts_parser_pkg = createPackage(b, "packages/ts_parser/src/ts_parser.zig", target, optimize, zig_test_framework);
    ts_parser_pkg.addImport("ts_lexer", ts_lexer_pkg);
    ts_parser_pkg.addImport("hir", hir_pkg);
    ts_parser_pkg.addImport("string_interner", string_interner_pkg);
    const ts_parser_prec_pkg = createPackage(b, "packages/ts_parser/src/precedence.zig", target, optimize, zig_test_framework);
    ts_parser_prec_pkg.addImport("ts_lexer", ts_lexer_pkg);
    ts_parser_prec_pkg.addImport("hir", hir_pkg);
    const d_ts_pkg = createPackage(b, "packages/d_ts/src/d_ts.zig", target, optimize, zig_test_framework);
    const tsconfig_jsonc_pkg = createPackage(b, "packages/tsconfig/src/jsonc.zig", target, optimize, zig_test_framework);
    const tsconfig_pkg = createPackage(b, "packages/tsconfig/src/tsconfig.zig", target, optimize, zig_test_framework);
    tsconfig_pkg.addImport("jsonc", tsconfig_jsonc_pkg);

    // Tier 0 `bun` compat shim — top-level peer of `bundler` so
    // any package that needs to compile against vendored Bun source
    // can `@import("compat")` (or wire it in under the
    // `bun` import name). Restored as a top-level package after the
    // initial vendored-bundler cleanup mistakenly removed it.
    const compat_pkg = createPackage(b, "packages/compat/src/compat.zig", target, optimize, zig_test_framework);

    // TS-parity Phase 2 — binder + symbol table.
    const binder_pkg = createPackage(b, "packages/binder/src/binder.zig", target, optimize, zig_test_framework);
    binder_pkg.addImport("hir", hir_pkg);
    binder_pkg.addImport("string_interner", string_interner_pkg);
    binder_pkg.addImport("ts_lexer", ts_lexer_pkg);
    binder_pkg.addImport("ts_parser", ts_parser_pkg);

    // TS-parity Phase 3 — type system foundation.
    const ts_checker_pkg = createPackage(b, "packages/ts_checker/src/ts_checker.zig", target, optimize, zig_test_framework);
    ts_checker_pkg.addImport("hir", hir_pkg);
    ts_checker_pkg.addImport("string_interner", string_interner_pkg);
    ts_checker_pkg.addImport("ts_lexer", ts_lexer_pkg);
    ts_checker_pkg.addImport("ts_parser", ts_parser_pkg);
    ts_checker_pkg.addImport("binder", binder_pkg);

    // TS-parity Phase 4 — JS / .d.ts emit + Home .d.hm.
    const ts_emit_pkg = createPackage(b, "packages/ts_emit/src/ts_emit.zig", target, optimize, zig_test_framework);
    ts_emit_pkg.addImport("hir", hir_pkg);
    ts_emit_pkg.addImport("string_interner", string_interner_pkg);
    ts_emit_pkg.addImport("ts_lexer", ts_lexer_pkg);
    ts_emit_pkg.addImport("ts_parser", ts_parser_pkg);

    // zig-dtsx fast-path .d.ts emitter — installed via pantry at
    // pantry/zig-dtsx/. `pantry add zig-dtsx` populates the directory;
    // CI restores it before build. Single-module root file
    // (zig_dtsx.zig) re-exports scanner + emitter; Zig requires each
    // file to belong to exactly one module so we can't expose
    // scanner and emitter as separate modules without duplication.
    const zig_dtsx_io = std.Io.Threaded.global_single_threaded.io();
    const zig_dtsx_source: std.Build.LazyPath = if (std.Io.Dir.cwd().access(zig_dtsx_io, "pantry/zig-dtsx/src/zig_dtsx.zig", .{})) |_|
        b.path("pantry/zig-dtsx/src/zig_dtsx.zig")
    else |_|
        // pantry/ is gitignored, so fresh checkouts / machines without
        // `pantry add @stacksjs/zig-dtsx` fall back to the committed
        // local stub (empty .d.ts output) so the build stays portable.
        b.path("packages/ts_emit/vendor/zig_dtsx_stub.zig");
    const dtsx_pkg = b.createModule(.{
        .root_source_file = zig_dtsx_source,
        .target = target,
        .optimize = optimize,
    });
    ts_emit_pkg.addImport("zig_dtsx", dtsx_pkg);
    ts_emit_pkg.addImport("ts_checker", ts_checker_pkg);

    const d_hm_pkg = createPackage(b, "packages/d_hm/src/d_hm.zig", target, optimize, zig_test_framework);
    d_hm_pkg.addImport("hir", hir_pkg);
    d_hm_pkg.addImport("string_interner", string_interner_pkg);
    // Tests inside d_hm parse TypeScript surface syntax into HIR (the
    // shared substrate) and verify the .d.hm re-printer renders Home
    // syntax. The ts_lexer/ts_parser deps are test-only.
    d_hm_pkg.addImport("ts_lexer", ts_lexer_pkg);
    d_hm_pkg.addImport("ts_parser", ts_parser_pkg);

    // TS-parity Phase 4.5 — driver wiring lex → parse → bind → emit.
    const ts_driver_pkg = createPackage(b, "packages/ts_driver/src/ts_driver.zig", target, optimize, zig_test_framework);
    ts_driver_pkg.addImport("hir", hir_pkg);
    ts_driver_pkg.addImport("string_interner", string_interner_pkg);
    ts_driver_pkg.addImport("ts_lexer", ts_lexer_pkg);
    ts_driver_pkg.addImport("ts_parser", ts_parser_pkg);
    ts_driver_pkg.addImport("binder", binder_pkg);
    ts_driver_pkg.addImport("ts_emit", ts_emit_pkg);
    ts_driver_pkg.addImport("tsconfig", tsconfig_pkg);
    ts_driver_pkg.addImport("ts_checker", ts_checker_pkg);

    // TS-parity Phase 1.E follow-up — module resolver.
    const ts_resolver_pkg = createPackage(b, "packages/ts_resolver/src/ts_resolver.zig", target, optimize, zig_test_framework);

    // TS-parity Phase 4 — tsc-compatible diagnostic formatter.
    const ts_diagnostics_pkg = createPackage(b, "packages/ts_diagnostics/src/ts_diagnostics.zig", target, optimize, zig_test_framework);

    // TS-parity Phase 4.5 — multi-file program graph.
    const ts_program_pkg = createPackage(b, "packages/ts_program/src/ts_program.zig", target, optimize, zig_test_framework);
    ts_program_pkg.addImport("hir", hir_pkg);
    ts_program_pkg.addImport("ts_driver", ts_driver_pkg);
    ts_program_pkg.addImport("ts_resolver", ts_resolver_pkg);
    ts_program_pkg.addImport("tsconfig", tsconfig_pkg);
    // Cross-module declaration-emit privacy (`cannot be named`) needs to
    // walk a resolved module's bound namespace member scopes.
    ts_program_pkg.addImport("binder", binder_pkg);

    // TS-parity §5.A.1 — Salsa-style incremental wrapper around
    // ts_program. Demonstrates per-file content-hash caching so
    // repeated `query()` calls skip unchanged files.
    const ts_query_pkg = createPackage(b, "packages/ts_query/src/ts_query.zig", target, optimize, zig_test_framework);
    ts_query_pkg.addImport("ts_program", ts_program_pkg);
    ts_query_pkg.addImport("ts_driver", ts_driver_pkg);
    ts_query_pkg.addImport("ts_resolver", ts_resolver_pkg);
    ts_query_pkg.addImport("binder", binder_pkg);

    // TS-parity Phase 4.5 — `home tsc` CLI.
    const ts_cli_pkg = createPackage(b, "packages/ts_cli/src/ts_cli.zig", target, optimize, zig_test_framework);
    ts_cli_pkg.addImport("ts_diagnostics", ts_diagnostics_pkg);
    ts_cli_pkg.addImport("ts_driver", ts_driver_pkg);
    ts_cli_pkg.addImport("ts_program", ts_program_pkg);
    ts_cli_pkg.addImport("ts_resolver", ts_resolver_pkg);
    ts_cli_pkg.addImport("tsconfig", tsconfig_pkg);

    // TS-parity Phase 6 — conformance harness.
    const ts_conformance_pkg = createPackage(b, "packages/ts_conformance/src/ts_conformance.zig", target, optimize, zig_test_framework);
    ts_conformance_pkg.addImport("hir", hir_pkg);
    ts_conformance_pkg.addImport("ts_driver", ts_driver_pkg);
    ts_conformance_pkg.addImport("ts_diagnostics", ts_diagnostics_pkg);
    // Multi-file fixtures route through the program graph + resolver
    // so module lookups flow through the same `ts_resolver` path a
    // real `home tsc` invocation would take. Single-file fixtures
    // fall through to the legacy `ts_driver.compileSource` route.
    ts_conformance_pkg.addImport("ts_program", ts_program_pkg);
    ts_conformance_pkg.addImport("ts_resolver", ts_resolver_pkg);
    ts_conformance_pkg.addImport("ts_checker", ts_checker_pkg);

    // TS-parity Phase 5 §5.7 — watch mode foundation.
    const ts_watch_pkg = createPackage(b, "packages/ts_watch/src/ts_watch.zig", target, optimize, zig_test_framework);

    // TS-parity Phase 8 — LSP foundation.
    const ts_lsp_pkg = createPackage(b, "packages/ts_lsp/src/ts_lsp.zig", target, optimize, zig_test_framework);
    ts_lsp_pkg.addImport("hir", hir_pkg);
    ts_lsp_pkg.addImport("ts_program", ts_program_pkg);
    ts_lsp_pkg.addImport("ts_driver", ts_driver_pkg);
    ts_lsp_pkg.addImport("ts_diagnostics", ts_diagnostics_pkg);
    ts_lsp_pkg.addImport("ts_resolver", ts_resolver_pkg);
    ts_lsp_pkg.addImport("ts_checker", ts_checker_pkg);
    ts_lsp_pkg.addImport("ts_lexer", ts_lexer_pkg);
    ts_lsp_pkg.addImport("string_interner", string_interner_pkg);

    // TS-parity Phase 5 §11.6 — persistent compilation cache.
    const ts_cache_pkg = createPackage(b, "packages/ts_cache/src/ts_cache.zig", target, optimize, zig_test_framework);
    // ts_driver consumes ts_cache for the emitWithCache fast path.
    ts_driver_pkg.addImport("ts_cache", ts_cache_pkg);
    // ts_program uses ts_cache for the multi-file emitAllToCache path.
    ts_program_pkg.addImport("ts_cache", ts_cache_pkg);

    // TS-parity Phase 8 — LSP wire-protocol JSON-RPC server.
    const ts_lsp_server_pkg = createPackage(b, "packages/ts_lsp_server/src/ts_lsp_server.zig", target, optimize, zig_test_framework);
    ts_lsp_server_pkg.addImport("ts_lsp", ts_lsp_pkg);
    ts_lsp_server_pkg.addImport("ts_program", ts_program_pkg);
    ts_lsp_server_pkg.addImport("ts_resolver", ts_resolver_pkg);
    ts_lsp_server_pkg.addImport("ts_diagnostics", ts_diagnostics_pkg);

    // TS-parity Phase 4.5 — bundler skeleton.
    const bundler_pkg = createPackage(b, "packages/bundler/src/bundler.zig", target, optimize, zig_test_framework);
    bundler_pkg.addImport("ts_program", ts_program_pkg);
    bundler_pkg.addImport("ts_resolver", ts_resolver_pkg);
    bundler_pkg.addImport("ts_driver", ts_driver_pkg);

    // Vendored Bun bundler sources under `bundler/src/` import
    // `@import("bun")` — wire that to the top-level `compat` shim
    // so the Tier 0 files (IndexStringMap.zig, PathToSourceIndexMap.zig)
    // compile. The `compat_tests.zig` test root sits at
    // `bundler/src/` so its relative `@import("bun/X.zig")` calls
    // pull in the vendored files; both the root and the recursed files
    // share the same import map, so `bun` resolves uniformly.
    const bundler_compat_pkg = createPackage(b, "packages/bundler/src/compat_tests.zig", target, optimize, zig_test_framework);
    bundler_compat_pkg.addImport("bun", compat_pkg);

    // TS-parity Phase 4.5+ — `home_test` (Bun's `bun:test` Zig source).
    // Vendored copy of upstream `bun/src/runtime/test_runner/*.zig`
    // (93 files) plus `bun/src/runtime/cli/test_command.zig` and the
    // `jest.classes.ts` bridge. MIT — see
    // packages/home_test/src/LICENSE.bun.md. Bun is shifting its core
    // to Rust; we own the Zig fork from here.
    //
    // For now we expose only the public facade
    // (packages/home_test/src/home_test.zig) as a buildable test
    // artifact; the vendored Bun runtime port lives at
    // packages/runtime/ where Chris's third-wave port batches land.
    const home_test_pkg = createPackage(b, "packages/home_test/src/home_test.zig", target, optimize, zig_test_framework);
    home_test_pkg.addImport("bun", compat_pkg);
    const home_test_bun_tier0_pkg = createPackage(b, "packages/home_test/src/bun_tier0_tests.zig", target, optimize, zig_test_framework);
    home_test_bun_tier0_pkg.addImport("bun", compat_pkg);
    const home_test_bun_tier1_pkg = createPackage(b, "packages/home_test/src/bun_tier1_tests.zig", target, optimize, zig_test_framework);
    home_test_bun_tier1_pkg.addImport("bun", compat_pkg);
    const home_test_bun_tier2_order_pkg = createPackage(b, "packages/home_test/src/bun_tier2_order_tests.zig", target, optimize, zig_test_framework);
    home_test_bun_tier2_order_pkg.addImport("bun", compat_pkg);
    const home_test_bun_tier2_collection_pkg = createPackage(b, "packages/home_test/src/bun_tier2_collection_tests.zig", target, optimize, zig_test_framework);
    home_test_bun_tier2_collection_pkg.addImport("bun", compat_pkg);
    const home_test_bun_tier2_done_callback_pkg = createPackage(b, "packages/home_test/src/bun_tier2_done_callback_tests.zig", target, optimize, zig_test_framework);
    home_test_bun_tier2_done_callback_pkg.addImport("bun", compat_pkg);
    const home_test_bun_tier2_debug_pkg = createPackage(b, "packages/home_test/src/bun_tier2_debug_tests.zig", target, optimize, zig_test_framework);
    home_test_bun_tier2_debug_pkg.addImport("bun", compat_pkg);
    const home_test_bun_tier2_diff_format_pkg = createPackage(b, "packages/home_test/src/bun_tier2_diff_format_tests.zig", target, optimize, zig_test_framework);
    home_test_bun_tier2_diff_format_pkg.addImport("bun", compat_pkg);
    const home_test_bun_tier2_execution_pkg = createPackage(b, "packages/home_test/src/bun_tier2_execution_tests.zig", target, optimize, zig_test_framework);
    home_test_bun_tier2_execution_pkg.addImport("bun", compat_pkg);
    const home_test_bun_expect_matcher_scaffold_pkg = createPackage(b, "packages/home_test/src/bun/expect_matcher_scaffold.zig", target, optimize, zig_test_framework);
    const home_test_bun_tier2_expect_matchers_pkg = createPackage(b, "packages/home_test/src/bun_tier2_expect_matchers_tests.zig", target, optimize, zig_test_framework);
    home_test_bun_tier2_expect_matchers_pkg.addImport("bun", home_test_bun_expect_matcher_scaffold_pkg);

    // ====================================================================
    // TS-parity binaries: `home-tsc` (compiler driver) + `home-lsp`
    // (Language Server Protocol stdio loop). Both consume the
    // packages above as plain libraries.
    // ====================================================================
    const home_tsc_exe = b.addExecutable(.{
        .name = "home-tsc",
        .root_module = b.createModule(.{
            .root_source_file = b.path("packages/ts_cli/src/tsc_main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    home_tsc_exe.root_module.addImport("ts_cli", ts_cli_pkg);
    home_tsc_exe.root_module.addImport("ts_program", ts_program_pkg);
    home_tsc_exe.root_module.addImport("ts_resolver", ts_resolver_pkg);
    home_tsc_exe.root_module.addImport("ts_driver", ts_driver_pkg);
    home_tsc_exe.root_module.addImport("ts_diagnostics", ts_diagnostics_pkg);
    home_tsc_exe.root_module.addImport("ts_emit", ts_emit_pkg);
    home_tsc_exe.root_module.addImport("tsconfig", tsconfig_pkg);
    home_tsc_exe.root_module.addImport("ts_watch", ts_watch_pkg);
    home_tsc_exe.root_module.addImport("d_hm", d_hm_pkg);
    b.installArtifact(home_tsc_exe);
    // Dedicated step so the TS compiler can be built in isolation,
    // independent of the runtime exes (`home`/`database`/…) which may be
    // mid-migration on a given Zig toolchain: `zig build home-tsc`.
    const home_tsc_step = b.step("home-tsc", "Build just the home-tsc TypeScript compiler");
    home_tsc_step.dependOn(&b.addInstallArtifact(home_tsc_exe, .{}).step);

    const home_lsp_exe = b.addExecutable(.{
        .name = "home-lsp",
        .root_module = b.createModule(.{
            .root_source_file = b.path("packages/ts_lsp_server/src/lsp_main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    home_lsp_exe.root_module.addImport("ts_lsp_server", ts_lsp_server_pkg);
    b.installArtifact(home_lsp_exe);
    const volatile_pkg = createPackage(b, "packages/volatile/src/volatile.zig", target, optimize, zig_test_framework);
    const pantry_pkg = createPackage(b, "packages/pantry/src/pantry.zig", target, optimize, zig_test_framework);
    const collections_pkg = createPackage(b, "packages/collections/src/collection.zig", target, optimize, zig_test_framework);
    const json_pkg = createPackage(b, "packages/json/src/json.zig", target, optimize, zig_test_framework);
    const file_pkg = createPackage(b, "packages/file/src/file.zig", target, optimize, zig_test_framework);
    const network_pkg = createPackage(b, "packages/network/src/network.zig", target, optimize, zig_test_framework);
    const http_pkg = createPackage(b, "packages/http/src/http.zig", target, optimize, zig_test_framework);

    // Cloud infrastructure package
    const cloud_pkg = createPackage(b, "packages/cloud/src/cloud.zig", target, optimize, zig_test_framework);

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

    // Home Runtime (Phase 12 substrate — Bun source copy in progress)
    // home_rt imports itself: copied-from-Bun source uses both
    // `@import("home_rt")` (older copied files rewritten at copy time) and
    // `@import("bun")` (verbatim copied files). Both aliases resolve to the
    // Home aggregator while preserving upstream provenance in source files.
    const home_rt_pkg = createPackage(b, "packages/runtime/src/home.zig", target, optimize, zig_test_framework);
    home_rt_pkg.addImport("home", home_rt_pkg);
    home_rt_pkg.addImport("bun", home_rt_pkg);
    home_test_pkg.addImport("home", home_rt_pkg);
    home_test_pkg.addImport("home_rt", home_rt_pkg);
    // JSC bring-up: the `ZigGeneratedClasses` module that `jsc/jsc.zig` imports
    // is generated by Bun's `src/codegen/generate-classes.ts`. The vendored
    // output lives at `.generated/ZigGeneratedClasses.zig`; it imports `bun`
    // (→ home_rt), so wire the aliases through.
    const zig_generated_classes = b.createModule(.{
        .root_source_file = b.path("packages/runtime/src/.generated/ZigGeneratedClasses.zig"),
        .target = target,
        .optimize = optimize,
    });
    zig_generated_classes.addImport("bun", home_rt_pkg);
    zig_generated_classes.addImport("home", home_rt_pkg);
    home_rt_pkg.addImport("ZigGeneratedClasses", zig_generated_classes);

    // Game development packages (order matters for dependencies)
    const game_assets_pkg = createPackage(b, "packages/game/src/assets.zig", target, optimize, zig_test_framework);
    game_assets_pkg.addImport("image", image_pkg);
    const game_replay_pkg = createPackage(b, "packages/game/src/replay.zig", target, optimize, zig_test_framework);
    const game_mods_pkg = createPackage(b, "packages/game/src/mods.zig", target, optimize, zig_test_framework);
    const game_loop_pkg = createPackage(b, "packages/game/src/game_loop.zig", target, optimize, zig_test_framework);
    const game_deterministic_pkg = createPackage(b, "packages/game/src/deterministic.zig", target, optimize, zig_test_framework);
    const game_ai_pkg = createPackage(b, "packages/game/src/ai.zig", target, optimize, zig_test_framework);
    const game_ecs_pkg = createPackage(b, "packages/game/src/ecs.zig", target, optimize, zig_test_framework);
    const game_network_pkg = createPackage(b, "packages/game/src/network.zig", target, optimize, zig_test_framework);

    // game_pkg depends on assets, replay, mods
    const game_pkg = createPackage(b, "packages/game/src/game.zig", target, optimize, zig_test_framework);
    game_pkg.addImport("game_assets", game_assets_pkg);
    game_pkg.addImport("game_replay", game_replay_pkg);
    game_pkg.addImport("game_mods", game_mods_pkg);
    game_pkg.addImport("game_deterministic", game_deterministic_pkg);

    // pathfinding depends on game (for Vec2)
    const game_pathfinding_pkg = createPackage(b, "packages/game/src/pathfinding.zig", target, optimize, zig_test_framework);
    game_pathfinding_pkg.addImport("game", game_pkg);

    // Setup dependencies between packages
    ast_pkg.addImport("lexer", lexer_pkg);
    parser_pkg.addImport("lexer", lexer_pkg);
    parser_pkg.addImport("ast", ast_pkg);
    diagnostics_pkg.addImport("ast", ast_pkg);
    parser_pkg.addImport("diagnostics", diagnostics_pkg);
    parser_pkg.addImport("macros", macros_pkg);
    types_pkg.addImport("ast", ast_pkg);
    types_pkg.addImport("diagnostics", diagnostics_pkg);
    types_pkg.addImport("traits", traits_pkg);
    types_pkg.addImport("lexer", lexer_pkg);
    types_pkg.addImport("parser", parser_pkg);
    traits_pkg.addImport("ast", ast_pkg);
    interpreter_pkg.addImport("ast", ast_pkg);
    comptime_pkg.addImport("ast", ast_pkg);
    types_pkg.addImport("comptime", comptime_pkg);
    generics_pkg.addImport("ast", ast_pkg);
    generics_pkg.addImport("types", types_pkg);
    generics_pkg.addImport("traits", traits_pkg);
    codegen_pkg.addImport("ast", ast_pkg);
    codegen_pkg.addImport("lexer", lexer_pkg);
    codegen_pkg.addImport("parser", parser_pkg);
    codegen_pkg.addImport("types", types_pkg);
    codegen_pkg.addImport("comptime", comptime_pkg);
    codegen_pkg.addImport("generics", generics_pkg);
    compiler_pkg.addImport("ast", ast_pkg);
    compiler_pkg.addImport("types", types_pkg);
    compiler_pkg.addImport("diagnostics", diagnostics_pkg);
    optimizer_pkg.addImport("ast", ast_pkg);
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

    // Link libc: the compiler itself uses the Zig std allocator +
    // posix APIs that pull in _malloc, _posix_memalign, _sigaction,
    // _realpath, _sysctlbyname, etc. on macOS.
    exe.root_module.link_libc = true;

    // Add package imports to main executable
    exe.root_module.addImport("lexer", lexer_pkg);
    exe.root_module.addImport("ast", ast_pkg);
    exe.root_module.addImport("parser", parser_pkg);
    exe.root_module.addImport("types", types_pkg);
    exe.root_module.addImport("interpreter", interpreter_pkg);
    exe.root_module.addImport("codegen", codegen_pkg);
    exe.root_module.addImport("compiler", compiler_pkg);
    exe.root_module.addImport("optimizer", optimizer_pkg);
    exe.root_module.addImport("formatter", formatter_pkg);
    exe.root_module.addImport("linter", linter_pkg);
    exe.root_module.addImport("macros", macros_pkg);
    exe.root_module.addImport("traits", traits_pkg);
    exe.root_module.addImport("diagnostics", diagnostics_pkg);
    exe.root_module.addImport("comptime", comptime_pkg);
    exe.root_module.addImport("pkg_manager", pkg_manager_pkg);
    exe.root_module.addImport("queue", queue_pkg);
    exe.root_module.addImport("database", database_pkg);
    exe.root_module.addImport("ir_cache", cache_pkg);
    exe.root_module.addImport("collections", collections_pkg);
    exe.root_module.addImport("json", json_pkg);
    exe.root_module.addImport("file", file_pkg);
    exe.root_module.addImport("network", network_pkg);
    exe.root_module.addImport("http", http_pkg);
    exe.root_module.addImport("cloud", cloud_pkg);
    exe.root_module.addImport("home_test", home_test_pkg);
    // `home eval`/`home run` reach the native JSC runtime through home_rt.
    // JSC itself is linked into `exe` below, gated on `enable_jsc`.
    exe.root_module.addImport("home", home_rt_pkg);
    exe.root_module.addImport("home_rt", home_rt_pkg);

    // Create build options module for conditional compilation
    const build_options = b.addOptions();
    build_options.addOption(bool, "enable_craft", enable_craft);
    build_options.addOption(bool, "debug_logging", debug_logging);
    build_options.addOption(bool, "memory_tracking", memory_tracking);
    build_options.addOption(bool, "enable_ir_cache", enable_ir_cache);
    build_options.addOption(bool, "parallel_build", parallel_build);
    build_options.addOption(bool, "extra_safety", extra_safety);
    build_options.addOption(bool, "enable_profiling", enable_profiling);
    build_options.addOption(bool, "enable_coverage", enable_coverage);
    build_options.addOption(bool, "enable_sanitize_address", enable_sanitize_address);
    build_options.addOption(bool, "enable_sanitize_undefined", enable_sanitize_undefined);
    build_options.addOption(bool, "enable_sanitize_thread", enable_sanitize_thread);
    build_options.addOption(bool, "enable_jsc", enable_jsc);
    build_options.addOption(bool, "enable_macros", enable_macros);
    build_options.addOption(bool, "override_no_export_cpp_apis", false);
    build_options.addOption(bool, "zig_self_hosted_backend", false);
    build_options.addOption([]const u8, "reported_nodejs_version", "24.0.0");
    build_options.addOption(bool, "baseline", false);
    build_options.addOption([]const u8, "sha", "");
    build_options.addOption(bool, "is_canary", false);
    build_options.addOption([]const u8, "canary_revision", "");
    build_options.addOption([]const u8, "base_path", "");
    build_options.addOption(bool, "enable_logs", debug_logging);
    build_options.addOption(bool, "enable_asan", enable_sanitize_address);
    build_options.addOption(bool, "enable_fuzzilli", false);
    build_options.addOption(bool, "enable_tinycc", false);
    build_options.addOption([]const u8, "codegen_path", "");
    build_options.addOption(bool, "codegen_embed", false);
    build_options.addOption(u8, "tracy_callstack_depth", 0);
    build_options.addOption(std.SemanticVersion, "version", .{
        .major = 1,
        .minor = 3,
        .patch = 14,
    });
    const build_options_module = build_options.createModule();

    // Add build options to executable
    exe.root_module.addImport("build_options", build_options_module);
    home_rt_pkg.addImport("build_options", build_options_module);
    home_test_pkg.addImport("build_options", build_options_module);
    home_rt_pkg.link_libc = true;
    if (target.result.os.tag == .macos) {
        home_rt_pkg.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/lib" });
    }
    home_rt_pkg.linkSystemLibrary("z", .{});
    home_rt_pkg.linkSystemLibrary("brotlidec", .{});
    home_rt_pkg.linkSystemLibrary("brotlienc", .{});
    home_rt_pkg.linkSystemLibrary("zstd", .{});
    if (enable_jsc) linkBunNative(b, home_rt_pkg, target);

    // Link Craft if enabled
    if (enable_craft) {
        std.debug.print("✅ Craft integration enabled\n", .{});
        std.debug.print("   Path: {s}\n", .{craft_path});

        // Add Craft include path
        const craft_src_path = b.fmt("{s}/src", .{craft_path});
        exe.root_module.addIncludePath(b.path(craft_src_path));

        // Link system libraries based on platform
        switch (target.result.os.tag) {
            .macos => {
                exe.root_module.linkFramework("Cocoa", .{});
                exe.root_module.linkFramework("WebKit", .{});
            },
            .linux => {
                exe.root_module.linkSystemLibrary("gtk-3", .{});
                exe.root_module.linkSystemLibrary("webkit2gtk-4.1", .{});
            },
            .windows => {
                exe.root_module.linkSystemLibrary("webview2", .{});
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
    if (zig_test_framework) |tf| {
        home_module.addImport("zig-test-framework", tf);
    }
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
    if (zig_test_framework) |tf| {
        http_router_module.addImport("zig-test-framework", tf);
    }

    const craft_module = b.createModule(.{
        .root_source_file = b.path("packages/basics/src/craft.zig"),
        .target = target,
        .optimize = optimize,
    });
    if (zig_test_framework) |tf| {
        craft_module.addImport("zig-test-framework", tf);
    }

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
    parser_tests.root_module.link_libc = true;
    if (zig_test_framework) |tf| {
        parser_tests.root_module.addImport("zig-test-framework", tf);
    }

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
    if (zig_test_framework) |tf| {
        http_router_tests.root_module.addImport("zig-test-framework", tf);
    }

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
    if (zig_test_framework) |tf| {
        craft_tests.root_module.addImport("zig-test-framework", tf);
    }

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
    queue_tests.root_module.link_libc = true;

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

    // ARM64 assembler tests (issue #5)
    const arm64_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("packages/codegen/tests/arm64_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    arm64_tests.root_module.addImport("codegen", codegen_pkg);
    // Needed for the JIT smoke tests' libc calls (mmap, pthread_jit_write_protect_np,
    // sys_icache_invalidate). Harmless on hosts where the JIT tests are skipped.
    arm64_tests.root_module.link_libc = true;

    const run_arm64_tests = b.addRunArtifact(arm64_tests);

    // Database tests (requires sqlite3 - skip on Windows and cross-compilation)
    const run_database_tests = if (target.result.os.tag != .windows and target.query.isNative()) blk: {
        const database_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("packages/database/tests/database_test.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        database_tests.root_module.addImport("database", database_pkg);
        database_tests.root_module.linkSystemLibrary("sqlite3", .{});
        database_tests.root_module.link_libc = true;

        break :blk b.addRunArtifact(database_tests);
    } else null;

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
    ffi_tests.root_module.link_libc = true;

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

    // Cloud tests
    const cloud_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("packages/cloud/tests/cloudformation_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    cloud_tests.root_module.addImport("cloud", cloud_pkg);

    const run_cloud_tests = b.addRunArtifact(cloud_tests);

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
    dependOnTest(test_step, &run_lexer_tests.step, test_filter, "lexer");
    dependOnTest(test_step, &run_parser_tests.step, test_filter, "parser");
    dependOnTest(test_step, &run_http_router_tests.step, test_filter, "http_router");
    dependOnTest(test_step, &run_craft_tests.step, test_filter, "craft");
    dependOnTest(test_step, &run_package_manager_tests.step, test_filter, "package_manager");
    dependOnTest(test_step, &run_queue_tests.step, test_filter, "queue");
    dependOnTest(test_step, &run_ast_tests.step, test_filter, "ast");
    dependOnTest(test_step, &run_diagnostics_tests.step, test_filter, "diagnostics");
    dependOnTest(test_step, &run_interpreter_tests.step, test_filter, "interpreter");
    dependOnTest(test_step, &run_formatter_tests.step, test_filter, "formatter");
    dependOnTest(test_step, &run_codegen_tests.step, test_filter, "codegen");
    dependOnTest(test_step, &run_arm64_tests.step, test_filter, "arm64");
    if (run_database_tests) |db_tests| dependOnTest(test_step, &db_tests.step, test_filter, "database");
    dependOnTest(test_step, &run_threading_tests.step, test_filter, "threading");
    dependOnTest(test_step, &run_memory_tests.step, test_filter, "memory");
    dependOnTest(test_step, &run_intrinsics_tests.step, test_filter, "intrinsics");
    dependOnTest(test_step, &run_ffi_tests.step, test_filter, "ffi");
    dependOnTest(test_step, &run_math_tests.step, test_filter, "math");
    dependOnTest(test_step, &run_env_tests.step, test_filter, "env");
    dependOnTest(test_step, &run_syscall_tests.step, test_filter, "syscall");
    dependOnTest(test_step, &run_signal_tests.step, test_filter, "signal");
    dependOnTest(test_step, &run_cloud_tests.step, test_filter, "cloud");
    dependOnTest(test_step, &run_mac_tests.step, test_filter, "mac");
    dependOnTest(test_step, &run_tpm_tests.step, test_filter, "tpm");

    // Game package tests
    const game_loop_tests = b.addTest(.{ .root_module = game_loop_pkg });
    const run_game_loop_tests = b.addRunArtifact(game_loop_tests);
    dependOnTest(test_step, &run_game_loop_tests.step, test_filter, "game_loop");

    const game_deterministic_tests = b.addTest(.{ .root_module = game_deterministic_pkg });
    const run_game_deterministic_tests = b.addRunArtifact(game_deterministic_tests);
    dependOnTest(test_step, &run_game_deterministic_tests.step, test_filter, "game_deterministic");

    const game_ecs_tests = b.addTest(.{ .root_module = game_ecs_pkg });
    const run_game_ecs_tests = b.addRunArtifact(game_ecs_tests);
    dependOnTest(test_step, &run_game_ecs_tests.step, test_filter, "game_ecs");

    const game_replay_tests = b.addTest(.{ .root_module = game_replay_pkg });
    const run_game_replay_tests = b.addRunArtifact(game_replay_tests);
    dependOnTest(test_step, &run_game_replay_tests.step, test_filter, "game_replay");

    // Home Runtime substrate tests
    const home_rt_tests = b.addTest(.{ .root_module = home_rt_pkg });
    // Pantry Zig's server-mode test runner deadlocks for the native-linked
    // home_rt binary before it sends the metadata query. Run this one artifact
    // in terminal mode while preserving the compiled test dependency.
    const run_home_rt_tests = b.addSystemCommand(&.{"/usr/bin/env"});
    run_home_rt_tests.setName("run test home_rt");
    run_home_rt_tests.addFileArg(home_rt_tests.getEmittedBin());
    run_home_rt_tests.addArg(b.fmt("--seed=0x{x}", .{b.graph.random_seed}));
    dependOnTest(test_step, &run_home_rt_tests.step, test_filter, "home_rt");

    // Modsign tests
    const modsign_tests = b.addTest(.{ .root_module = modsign_pkg });
    const run_modsign_tests = b.addRunArtifact(modsign_tests);
    dependOnTest(test_step, &run_modsign_tests.step, test_filter, "modsign");

    // Coredump tests
    const coredump_tests = b.addTest(.{ .root_module = coredump_pkg });
    const run_coredump_tests = b.addRunArtifact(coredump_tests);
    dependOnTest(test_step, &run_coredump_tests.step, test_filter, "coredump");

    // Syslog tests
    const syslog_tests = b.addTest(.{ .root_module = syslog_pkg });
    const run_syslog_tests = b.addRunArtifact(syslog_tests);
    dependOnTest(test_step, &run_syslog_tests.step, test_filter, "syslog");

    // USB security tests
    const usb_tests = b.addTest(.{ .root_module = usb_pkg });
    const run_usb_tests = b.addRunArtifact(usb_tests);
    dependOnTest(test_step, &run_usb_tests.step, test_filter, "usb");

    // IOMMU tests
    const iommu_tests = b.addTest(.{ .root_module = iommu_pkg });
    const run_iommu_tests = b.addRunArtifact(iommu_tests);
    dependOnTest(test_step, &run_iommu_tests.step, test_filter, "iommu");

    // Timing attack mitigation tests
    const timing_tests = b.addTest(.{ .root_module = timing_pkg });
    const run_timing_tests = b.addRunArtifact(timing_tests);
    dependOnTest(test_step, &run_timing_tests.step, test_filter, "timing");

    // Bootloader tests
    const bootloader_tests = b.addTest(.{ .root_module = bootloader_pkg });
    const run_bootloader_tests = b.addRunArtifact(bootloader_tests);
    dependOnTest(test_step, &run_bootloader_tests.step, test_filter, "bootloader");

    // IPv6 networking tests
    const ipv6_tests = b.addTest(.{ .root_module = ipv6_pkg });
    const run_ipv6_tests = b.addRunArtifact(ipv6_tests);
    dependOnTest(test_step, &run_ipv6_tests.step, test_filter, "ipv6");

    // Device Tree Binary tests
    const dtb_tests = b.addTest(.{ .root_module = dtb_pkg });
    const run_dtb_tests = b.addRunArtifact(dtb_tests);
    dependOnTest(test_step, &run_dtb_tests.step, test_filter, "dtb");

    // Hardware drivers tests
    const drivers_tests = b.addTest(.{ .root_module = drivers_pkg });
    const run_drivers_tests = b.addRunArtifact(drivers_tests);
    dependOnTest(test_step, &run_drivers_tests.step, test_filter, "drivers");

    // Variadic functions tests
    const variadic_tests = b.addTest(.{ .root_module = variadic_pkg });
    const run_variadic_tests = b.addRunArtifact(variadic_tests);
    dependOnTest(test_step, &run_variadic_tests.step, test_filter, "variadic");

    // Inline functions tests
    const inline_tests = b.addTest(.{ .root_module = inline_pkg });
    const run_inline_tests = b.addRunArtifact(inline_tests);
    dependOnTest(test_step, &run_inline_tests.step, test_filter, "inline");

    // Register allocation tests
    const regalloc_tests = b.addTest(.{ .root_module = regalloc_pkg });
    const run_regalloc_tests = b.addRunArtifact(regalloc_tests);
    dependOnTest(test_step, &run_regalloc_tests.step, test_filter, "regalloc");

    // Platform-specific code blocks tests
    const platform_tests = b.addTest(.{ .root_module = platform_pkg });
    const run_platform_tests = b.addRunArtifact(platform_tests);
    dependOnTest(test_step, &run_platform_tests.step, test_filter, "platform");

    // TS-parity Phase 0 infrastructure tests
    const arena_tests = b.addTest(.{ .root_module = arena_pkg });
    const run_arena_tests = b.addRunArtifact(arena_tests);
    dependOnTest(test_step, &run_arena_tests.step, test_filter, "arena");

    const string_interner_tests = b.addTest(.{ .root_module = string_interner_pkg });
    const run_string_interner_tests = b.addRunArtifact(string_interner_tests);
    dependOnTest(test_step, &run_string_interner_tests.step, test_filter, "string_interner");

    const hir_tests = b.addTest(.{ .root_module = hir_pkg });
    const run_hir_tests = b.addRunArtifact(hir_tests);
    dependOnTest(test_step, &run_hir_tests.step, test_filter, "hir");

    const query_tests = b.addTest(.{ .root_module = query_pkg });
    const run_query_tests = b.addRunArtifact(query_tests);
    dependOnTest(test_step, &run_query_tests.step, test_filter, "query");

    const parsers_precedence_tests = b.addTest(.{ .root_module = parsers_precedence_pkg });
    const run_parsers_precedence_tests = b.addRunArtifact(parsers_precedence_tests);
    dependOnTest(test_step, &run_parsers_precedence_tests.step, test_filter, "parsers_precedence");

    const native_layouts_tests = b.addTest(.{ .root_module = native_layouts_pkg });
    const run_native_layouts_tests = b.addRunArtifact(native_layouts_tests);
    dependOnTest(test_step, &run_native_layouts_tests.step, test_filter, "native_layouts");

    const ts_lexer_tests = b.addTest(.{ .root_module = ts_lexer_pkg });
    const run_ts_lexer_tests = b.addRunArtifact(ts_lexer_tests);
    dependOnTest(test_step, &run_ts_lexer_tests.step, test_filter, "ts_lexer");

    const ts_parser_tests = b.addTest(.{ .root_module = ts_parser_pkg });
    const run_ts_parser_tests = b.addRunArtifact(ts_parser_tests);
    dependOnTest(test_step, &run_ts_parser_tests.step, test_filter, "ts_parser");

    const ts_parser_prec_tests = b.addTest(.{ .root_module = ts_parser_prec_pkg });
    const run_ts_parser_prec_tests = b.addRunArtifact(ts_parser_prec_tests);
    dependOnTest(test_step, &run_ts_parser_prec_tests.step, test_filter, "ts_parser_precedence");

    const d_ts_tests = b.addTest(.{ .root_module = d_ts_pkg });
    const run_d_ts_tests = b.addRunArtifact(d_ts_tests);
    dependOnTest(test_step, &run_d_ts_tests.step, test_filter, "d_ts");

    const tsconfig_jsonc_tests = b.addTest(.{ .root_module = tsconfig_jsonc_pkg });
    const run_tsconfig_jsonc_tests = b.addRunArtifact(tsconfig_jsonc_tests);
    dependOnTest(test_step, &run_tsconfig_jsonc_tests.step, test_filter, "tsconfig_jsonc");

    const tsconfig_tests = b.addTest(.{ .root_module = tsconfig_pkg });
    const run_tsconfig_tests = b.addRunArtifact(tsconfig_tests);
    dependOnTest(test_step, &run_tsconfig_tests.step, test_filter, "tsconfig");

    const binder_tests = b.addTest(.{ .root_module = binder_pkg });
    const run_binder_tests = b.addRunArtifact(binder_tests);
    dependOnTest(test_step, &run_binder_tests.step, test_filter, "binder");

    const compat_tests = b.addTest(.{ .root_module = compat_pkg });
    const run_compat_tests = b.addRunArtifact(compat_tests);
    dependOnTest(test_step, &run_compat_tests.step, test_filter, "compat");

    const ts_checker_tests = b.addTest(.{ .root_module = ts_checker_pkg });
    const run_ts_checker_tests = b.addRunArtifact(ts_checker_tests);
    dependOnTest(test_step, &run_ts_checker_tests.step, test_filter, "ts_checker");

    const ts_emit_tests = b.addTest(.{ .root_module = ts_emit_pkg });
    const run_ts_emit_tests = b.addRunArtifact(ts_emit_tests);
    dependOnTest(test_step, &run_ts_emit_tests.step, test_filter, "ts_emit");

    const d_hm_tests = b.addTest(.{ .root_module = d_hm_pkg });
    const run_d_hm_tests = b.addRunArtifact(d_hm_tests);
    dependOnTest(test_step, &run_d_hm_tests.step, test_filter, "d_hm");

    const ts_driver_tests = b.addTest(.{ .root_module = ts_driver_pkg });
    const run_ts_driver_tests = b.addRunArtifact(ts_driver_tests);
    dependOnTest(test_step, &run_ts_driver_tests.step, test_filter, "ts_driver");

    const ts_resolver_tests = b.addTest(.{ .root_module = ts_resolver_pkg });
    const run_ts_resolver_tests = b.addRunArtifact(ts_resolver_tests);
    dependOnTest(test_step, &run_ts_resolver_tests.step, test_filter, "ts_resolver");

    const ts_diagnostics_tests = b.addTest(.{ .root_module = ts_diagnostics_pkg });
    const run_ts_diagnostics_tests = b.addRunArtifact(ts_diagnostics_tests);
    dependOnTest(test_step, &run_ts_diagnostics_tests.step, test_filter, "ts_diagnostics");

    const ts_program_tests = b.addTest(.{ .root_module = ts_program_pkg });
    const run_ts_program_tests = b.addRunArtifact(ts_program_tests);
    dependOnTest(test_step, &run_ts_program_tests.step, test_filter, "ts_program");

    const ts_query_tests = b.addTest(.{ .root_module = ts_query_pkg });
    const run_ts_query_tests = b.addRunArtifact(ts_query_tests);
    dependOnTest(test_step, &run_ts_query_tests.step, test_filter, "ts_query");

    const ts_cli_tests = b.addTest(.{ .root_module = ts_cli_pkg });
    const run_ts_cli_tests = b.addRunArtifact(ts_cli_tests);
    dependOnTest(test_step, &run_ts_cli_tests.step, test_filter, "ts_cli");

    const ts_conformance_test_filters: []const []const u8 = if (ts_conformance_test_filter) |needle| &.{needle} else &.{};
    const ts_conformance_tests = b.addTest(.{
        .root_module = ts_conformance_pkg,
        .filters = ts_conformance_test_filters,
    });
    const run_ts_conformance_tests = b.addRunArtifact(ts_conformance_tests);
    dependOnTest(test_step, &run_ts_conformance_tests.step, test_filter, "ts_conformance");

    const ts_watch_tests = b.addTest(.{ .root_module = ts_watch_pkg });
    const run_ts_watch_tests = b.addRunArtifact(ts_watch_tests);
    dependOnTest(test_step, &run_ts_watch_tests.step, test_filter, "ts_watch");

    const ts_lsp_tests = b.addTest(.{ .root_module = ts_lsp_pkg });
    const run_ts_lsp_tests = b.addRunArtifact(ts_lsp_tests);
    dependOnTest(test_step, &run_ts_lsp_tests.step, test_filter, "ts_lsp");

    const ts_cache_tests = b.addTest(.{ .root_module = ts_cache_pkg });
    const run_ts_cache_tests = b.addRunArtifact(ts_cache_tests);
    dependOnTest(test_step, &run_ts_cache_tests.step, test_filter, "ts_cache");

    const ts_lsp_server_tests = b.addTest(.{ .root_module = ts_lsp_server_pkg });
    const run_ts_lsp_server_tests = b.addRunArtifact(ts_lsp_server_tests);
    dependOnTest(test_step, &run_ts_lsp_server_tests.step, test_filter, "ts_lsp_server");

    const bundler_tests = b.addTest(.{ .root_module = bundler_pkg });
    const run_bundler_tests = b.addRunArtifact(bundler_tests);
    dependOnTest(test_step, &run_bundler_tests.step, test_filter, "bundler");

    const bundler_compat_tests = b.addTest(.{ .root_module = bundler_compat_pkg });
    const run_bundler_compat_tests = b.addRunArtifact(bundler_compat_tests);
    dependOnTest(test_step, &run_bundler_compat_tests.step, test_filter, "bundler_compat");

    // home_test: only the public facade is wired in.
    const home_test_tests = b.addTest(.{ .root_module = home_test_pkg });
    const run_home_test_tests = b.addRunArtifact(home_test_tests);
    dependOnTest(test_step, &run_home_test_tests.step, test_filter, "home_test");

    const home_test_bun_tier0_tests = b.addTest(.{
        .root_module = home_test_bun_tier0_pkg,
        .filters = &.{"copied Bun"},
    });
    const run_home_test_bun_tier0_tests = b.addRunArtifact(home_test_bun_tier0_tests);
    dependOnTest(test_step, &run_home_test_bun_tier0_tests.step, test_filter, "home_test_bun_tier0");

    const home_test_bun_tier1_tests = b.addTest(.{
        .root_module = home_test_bun_tier1_pkg,
        .filters = &.{"copied Bun"},
    });
    const run_home_test_bun_tier1_tests = b.addRunArtifact(home_test_bun_tier1_tests);
    dependOnTest(test_step, &run_home_test_bun_tier1_tests.step, test_filter, "home_test_bun_tier1");

    const home_test_bun_tier2_order_tests = b.addTest(.{
        .root_module = home_test_bun_tier2_order_pkg,
        .filters = &.{"copied Bun"},
    });
    const run_home_test_bun_tier2_order_tests = b.addRunArtifact(home_test_bun_tier2_order_tests);
    dependOnTest(test_step, &run_home_test_bun_tier2_order_tests.step, test_filter, "home_test_bun_tier2_order");

    const home_test_bun_tier2_collection_tests = b.addTest(.{
        .root_module = home_test_bun_tier2_collection_pkg,
        .filters = &.{"copied Bun"},
    });
    const run_home_test_bun_tier2_collection_tests = b.addRunArtifact(home_test_bun_tier2_collection_tests);
    dependOnTest(test_step, &run_home_test_bun_tier2_collection_tests.step, test_filter, "home_test_bun_tier2_collection");

    const home_test_bun_tier2_done_callback_tests = b.addTest(.{
        .root_module = home_test_bun_tier2_done_callback_pkg,
        .filters = &.{"copied Bun"},
    });
    const run_home_test_bun_tier2_done_callback_tests = b.addRunArtifact(home_test_bun_tier2_done_callback_tests);
    dependOnTest(test_step, &run_home_test_bun_tier2_done_callback_tests.step, test_filter, "home_test_bun_tier2_done_callback");

    const home_test_bun_tier2_debug_tests = b.addTest(.{
        .root_module = home_test_bun_tier2_debug_pkg,
        .filters = &.{"copied Bun"},
    });
    const run_home_test_bun_tier2_debug_tests = b.addRunArtifact(home_test_bun_tier2_debug_tests);
    dependOnTest(test_step, &run_home_test_bun_tier2_debug_tests.step, test_filter, "home_test_bun_tier2_debug");

    const home_test_bun_tier2_diff_format_tests = b.addTest(.{
        .root_module = home_test_bun_tier2_diff_format_pkg,
        .filters = &.{"copied Bun"},
    });
    const run_home_test_bun_tier2_diff_format_tests = b.addRunArtifact(home_test_bun_tier2_diff_format_tests);
    dependOnTest(test_step, &run_home_test_bun_tier2_diff_format_tests.step, test_filter, "home_test_bun_tier2_diff_format");

    const home_test_bun_tier2_execution_tests = b.addTest(.{
        .root_module = home_test_bun_tier2_execution_pkg,
        .filters = &.{"copied Bun"},
    });
    const run_home_test_bun_tier2_execution_tests = b.addRunArtifact(home_test_bun_tier2_execution_tests);
    dependOnTest(test_step, &run_home_test_bun_tier2_execution_tests.step, test_filter, "home_test_bun_tier2_execution");

    const home_test_bun_tier2_expect_matchers_tests = b.addTest(.{
        .root_module = home_test_bun_tier2_expect_matchers_pkg,
        .filters = &.{"copied Bun"},
    });
    const run_home_test_bun_tier2_expect_matchers_tests = b.addRunArtifact(home_test_bun_tier2_expect_matchers_tests);
    dependOnTest(test_step, &run_home_test_bun_tier2_expect_matchers_tests.step, test_filter, "home_test_bun_tier2_expect_matchers");

    // Volatile operations tests
    const volatile_tests = b.addTest(.{ .root_module = volatile_pkg });
    const run_volatile_tests = b.addRunArtifact(volatile_tests);
    dependOnTest(test_step, &run_volatile_tests.step, test_filter, "volatile");

    // Pantry tests
    const pantry_tests = b.addTest(.{ .root_module = pantry_pkg });
    const run_pantry_tests = b.addRunArtifact(pantry_tests);
    dependOnTest(test_step, &run_pantry_tests.step, test_filter, "pantry");

    // ════════════════════════════════════════════════════════════════
    // Diagnostic snapshot tests
    // ════════════════════════════════════════════════════════════════
    //
    // Runs the `home` compiler against representative bad programs in
    // `tests/diagnostics/cases/` and compares stderr to checked-in
    // `.expected` snapshots. Any drift in error-message UX fails CI.
    //
    //   zig build test-diagnostics                # verify
    //   zig build test-diagnostics -- --update    # accept new output
    //
    // The harness depends on a freshly-installed `home` binary so it
    // tests what users actually get.
    const diag_harness = b.addExecutable(.{
        .name = "diagnostic-harness",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/diagnostics/harness.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_diag_harness = b.addRunArtifact(diag_harness);
    run_diag_harness.step.dependOn(b.getInstallStep());
    run_diag_harness.addArg(b.build_root.path orelse ".");
    run_diag_harness.addFileArg(exe.getEmittedBin());
    if (b.args) |args| run_diag_harness.addArgs(args);

    const test_diagnostics_step = b.step(
        "test-diagnostics",
        "Run diagnostic snapshot tests (pass --update to refresh snapshots)",
    );
    test_diagnostics_step.dependOn(&run_diag_harness.step);

    // Fold into the umbrella `test` step so `zig build test` covers
    // diagnostic regressions too.
    dependOnTest(test_step, &run_diag_harness.step, test_filter, "diagnostics");

    // ════════════════════════════════════════════════════════════════
    // Fuzzing (issue #10)
    // ════════════════════════════════════════════════════════════════
    //
    // Mutation-based fuzzer for the lexer (`home parse`) and parser
    // (`home ast`). Runs the compiler in a subprocess per iteration so
    // we can enforce a hard wall-clock timeout — the parser is known
    // to infinite-loop on certain malformed inputs (issue #16) and an
    // in-process fuzzer would wedge itself.
    //
    //   zig build fuzz                        # both targets, 60s budget total
    //   zig build fuzz-lexer                  # lexer only
    //   zig build fuzz-parser                 # parser only
    //   zig build fuzz -- --seconds 30        # custom budget
    //
    // The harness fails (exits non-zero) only on actual crashes
    // (signal / unexpected exit code). Timeouts are saved as findings
    // for issue #16 but do NOT fail the build.
    const fuzz_harness = b.addExecutable(.{
        .name = "fuzz-harness",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/fuzz/harness.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // Per-target run helpers. Each gets its own RunArtifact so the
    // step graph stays clean.
    const fuzz_lexer_run = b.addRunArtifact(fuzz_harness);
    fuzz_lexer_run.step.dependOn(b.getInstallStep());
    fuzz_lexer_run.addArg(b.build_root.path orelse ".");
    fuzz_lexer_run.addFileArg(exe.getEmittedBin());
    fuzz_lexer_run.addArg("lex");
    if (b.args) |args| fuzz_lexer_run.addArgs(args);

    const fuzz_parser_run = b.addRunArtifact(fuzz_harness);
    fuzz_parser_run.step.dependOn(b.getInstallStep());
    fuzz_parser_run.addArg(b.build_root.path orelse ".");
    fuzz_parser_run.addFileArg(exe.getEmittedBin());
    fuzz_parser_run.addArg("parse");
    if (b.args) |args| fuzz_parser_run.addArgs(args);

    const fuzz_all_run = b.addRunArtifact(fuzz_harness);
    fuzz_all_run.step.dependOn(b.getInstallStep());
    fuzz_all_run.addArg(b.build_root.path orelse ".");
    fuzz_all_run.addFileArg(exe.getEmittedBin());
    fuzz_all_run.addArg("all");
    if (b.args) |args| fuzz_all_run.addArgs(args);

    const fuzz_lexer_step = b.step(
        "fuzz-lexer",
        "Fuzz the lexer (subprocess-isolated; timeouts logged, crashes fail)",
    );
    fuzz_lexer_step.dependOn(&fuzz_lexer_run.step);

    const fuzz_parser_step = b.step(
        "fuzz-parser",
        "Fuzz the parser (subprocess-isolated; timeouts logged, crashes fail)",
    );
    fuzz_parser_step.dependOn(&fuzz_parser_run.step);

    const fuzz_step = b.step(
        "fuzz",
        "Fuzz lexer + parser (umbrella; pass --seconds N to size the budget)",
    );
    fuzz_step.dependOn(&fuzz_all_run.step);

    // Test zig-test-framework integration (only if framework is available)
    if (zig_test_framework) |tf| {
        const framework_integration_mod = b.createModule(.{
            .root_source_file = b.path("packages/build/test_framework_integration.zig"),
            .target = target,
            .optimize = optimize,
        });
        framework_integration_mod.addImport("zig-test-framework", tf);

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
        coverage_runner.root_module.addImport("zig-test-framework", tf);
        b.installArtifact(coverage_runner);

        const run_coverage_runner = b.addRunArtifact(coverage_runner);
        const coverage_step = b.step("coverage", "Run coverage test runner");
        coverage_step.dependOn(&run_coverage_runner.step);
    }

    // Parallel test runner with caching and benchmarking
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
    parser_bench.root_module.link_libc = true;

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
    queue_example.root_module.link_libc = true;
    b.installArtifact(queue_example);

    const run_queue_example = b.addRunArtifact(queue_example);
    const queue_example_step = b.step("example-queue", "Run queue system example");
    queue_example_step.dependOn(&run_queue_example.step);

    // Database Example (requires sqlite3 system library - skip on Windows and cross-compilation)
    const is_windows = target.result.os.tag == .windows;
    const is_native = target.query.isNative();

    if (!is_windows and is_native) {
        const database_example = b.addExecutable(.{
            .name = "database_example",
            .root_module = b.createModule(.{
                .root_source_file = b.path("examples/database_example.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        database_example.root_module.addImport("database", database_pkg);
        database_example.root_module.linkSystemLibrary("sqlite3", .{});
        database_example.root_module.link_libc = true;
        b.installArtifact(database_example);

        const run_database_example = b.addRunArtifact(database_example);
        const database_example_step = b.step("example-database", "Run database example");
        database_example_step.dependOn(&run_database_example.step);
    }

    // Generals Engine Example (C&C Generals recreation - macOS only).
    // Opt-in via `-Dgenerals=true` to keep the default build fast.
    const is_macos = target.result.os.tag == .macos;
    const build_generals = b.option(bool, "generals", "Build the C&C Generals engine example (macOS only)") orelse false;

    if (is_macos and build_generals) {
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
        // W3D model loading
        const w3d_loader_pkg = createPackage(b, "packages/game/src/w3d_loader.zig", target, optimize, zig_test_framework);
        generals_example.root_module.addImport("w3d_loader", w3d_loader_pkg);

        // Resolve Xcode SDK so frameworks like Cocoa/OpenGL/OpenAL/AudioToolbox
        // are findable under the Pantry-pinned Zig 0.17 dev toolchain.
        const sdk_path = macosSdkPath(b, target);
        const fw_path = b.fmt("{s}/System/Library/Frameworks", .{sdk_path});
        const lib_path = b.fmt("{s}/usr/lib", .{sdk_path});
        generals_example.root_module.addSystemFrameworkPath(.{ .cwd_relative = fw_path });
        generals_example.root_module.addLibraryPath(.{ .cwd_relative = lib_path });

        // Link macOS frameworks
        generals_example.root_module.linkFramework("Cocoa", .{});
        generals_example.root_module.linkFramework("OpenGL", .{});
        generals_example.root_module.linkFramework("OpenAL", .{});
        generals_example.root_module.linkFramework("AudioToolbox", .{});
        generals_example.root_module.link_libc = true;
        b.installArtifact(generals_example);

        const run_generals_example = b.addRunArtifact(generals_example);
        const generals_example_step = b.step("generals", "Run C&C Generals engine example");
        generals_example_step.dependOn(&run_generals_example.step);
    }

    // Run all examples
    const examples_step = b.step("examples", "Run all examples");
    examples_step.dependOn(&run_http_router_example.step);
    examples_step.dependOn(&run_craft_example.step);
    examples_step.dependOn(&run_fullstack_example.step);
    examples_step.dependOn(&run_queue_example.step);

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
    debug_exe.root_module.addImport("compiler", compiler_pkg);
    debug_exe.root_module.addImport("optimizer", optimizer_pkg);
    debug_exe.root_module.addImport("formatter", formatter_pkg);
    debug_exe.root_module.addImport("linter", linter_pkg);
    debug_exe.root_module.addImport("macros", macros_pkg);
    debug_exe.root_module.addImport("traits", traits_pkg);
    debug_exe.root_module.addImport("diagnostics", diagnostics_pkg);
    debug_exe.root_module.addImport("comptime", comptime_pkg);
    debug_exe.root_module.addImport("pkg_manager", pkg_manager_pkg);
    debug_exe.root_module.addImport("queue", queue_pkg);
    debug_exe.root_module.addImport("database", database_pkg);
    debug_exe.root_module.addImport("ir_cache", cache_pkg);
    debug_exe.root_module.addImport("collections", collections_pkg);
    debug_exe.root_module.addImport("json", json_pkg);
    debug_exe.root_module.addImport("file", file_pkg);
    debug_exe.root_module.addImport("network", network_pkg);
    debug_exe.root_module.addImport("http", http_pkg);
    debug_exe.root_module.addImport("cloud", cloud_pkg);
    debug_exe.root_module.addImport("home_test", home_test_pkg);
    debug_exe.root_module.addImport("build_options", build_options_module);
    debug_exe.root_module.addImport("home", home_rt_pkg);
    debug_exe.root_module.addImport("home_rt", home_rt_pkg);

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
    release_safe_exe.root_module.addImport("comptime", comptime_pkg);
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
    release_safe_exe.root_module.addImport("home", home_rt_pkg);
    release_safe_exe.root_module.addImport("home_rt", home_rt_pkg);

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
    release_small_exe.root_module.addImport("comptime", comptime_pkg);
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
    release_small_exe.root_module.addImport("home", home_rt_pkg);
    release_small_exe.root_module.addImport("home_rt", home_rt_pkg);

    const install_release_small = b.addInstallArtifact(release_small_exe, .{});
    const release_small_step = b.step("release-small", "Build Home compiler in ReleaseSmall mode (optimized for size)");
    release_small_step.dependOn(&install_release_small.step);

    // Release-fast build (max performance, no safety, LTO).
    // §5.A.4 — PGO + LTO build flag for the Home toolchain itself.
    // PGO requires a profile-collection run; the LTO bit lights up
    // here. To collect a profile: run a corpus through the resulting
    // binary, then re-link with the captured `.profdata`. Documented
    // in CONTRIBUTING.md (Phase 5 follow-up).
    const release_fast_exe = b.addExecutable(.{
        .name = "home-release-fast",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = .ReleaseFast,
        }),
    });
    release_fast_exe.root_module.addImport("lexer", lexer_pkg);
    release_fast_exe.root_module.addImport("ast", ast_pkg);
    release_fast_exe.root_module.addImport("parser", parser_pkg);
    release_fast_exe.root_module.addImport("types", types_pkg);
    release_fast_exe.root_module.addImport("interpreter", interpreter_pkg);
    release_fast_exe.root_module.addImport("codegen", codegen_pkg);
    release_fast_exe.root_module.addImport("formatter", formatter_pkg);
    release_fast_exe.root_module.addImport("linter", linter_pkg);
    release_fast_exe.root_module.addImport("traits", traits_pkg);
    release_fast_exe.root_module.addImport("diagnostics", diagnostics_pkg);
    release_fast_exe.root_module.addImport("comptime", comptime_pkg);
    release_fast_exe.root_module.addImport("pkg_manager", pkg_manager_pkg);
    release_fast_exe.root_module.addImport("queue", queue_pkg);
    release_fast_exe.root_module.addImport("database", database_pkg);
    release_fast_exe.root_module.addImport("ir_cache", cache_pkg);
    release_fast_exe.root_module.addImport("collections", collections_pkg);
    release_fast_exe.root_module.addImport("json", json_pkg);
    release_fast_exe.root_module.addImport("file", file_pkg);
    release_fast_exe.root_module.addImport("network", network_pkg);
    release_fast_exe.root_module.addImport("http", http_pkg);
    release_fast_exe.root_module.addImport("build_options", build_options.createModule());
    release_fast_exe.root_module.addImport("home", home_rt_pkg);
    release_fast_exe.root_module.addImport("home_rt", home_rt_pkg);
    // LTO is enabled by default for ReleaseFast under modern Zig
    // (whole-program optimization across modules). The §11.11
    // Tier 1 ~10–20% speedup baseline kicks in here automatically.
    const install_release_fast = b.addInstallArtifact(release_fast_exe, .{});
    const release_fast_step = b.step("release-fast", "Build Home compiler in ReleaseFast mode with LTO (max perf, no runtime safety)");
    release_fast_step.dependOn(&install_release_fast.step);

    // Documentation generation
    const docs_install = b.addInstallDirectory(.{
        .source_dir = exe.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });

    const docs_step = b.step("docs", "Generate documentation for Home");
    docs_step.dependOn(&docs_install.step);
}
