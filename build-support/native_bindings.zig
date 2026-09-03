const std = @import("std");

const CompileCommand = struct {
    directory: []const u8,
    file: []const u8,
    arguments: []const []const u8,
};

var cached_process_object: ?std.Build.LazyPath = null;
var cached_registry_object: ?std.Build.LazyPath = null;
var cached_script_execution_context_object: ?std.Build.LazyPath = null;
var cached_napi_object: ?std.Build.LazyPath = null;
var cached_global_gc_object: ?std.Build.LazyPath = null;
var cached_message_port_object: ?std.Build.LazyPath = null;
var cached_message_port_pipe_object: ?std.Build.LazyPath = null;
var cached_worker_object: ?std.Build.LazyPath = null;
var cached_worker_scope_object: ?std.Build.LazyPath = null;
var cached_js_message_port_object: ?std.Build.LazyPath = null;
var cached_js_abort_signal_object: ?std.Build.LazyPath = null;
var cached_uws_object: ?std.Build.LazyPath = null;
var cached_native_modules: ?std.Build.LazyPath = null;

/// Rebuild the Home-owned process binding with the headers and ABI flags that
/// produced the rest of the linked Bun objects. Never silently use the stale
/// external object when its source differs from Home's implementation.
pub fn processObject(b: *std.Build, object_root: []const u8) std.Build.LazyPath {
    if (cached_process_object) |object| return object;
    const files = b.addWriteFiles();
    const source = files.addCopyFile(b.path("packages/runtime/upstream/src/jsc/bindings/BunProcess.cpp"), "BunProcess.cpp");
    const object = compileObject(b, object_root, "BunProcess.cpp", source);
    cached_process_object = object;
    return object;
}

pub fn napiObject(b: *std.Build, object_root: []const u8) std.Build.LazyPath {
    if (cached_napi_object) |object| return object;
    const files = b.addWriteFiles();
    const source = files.addCopyFile(b.path("packages/runtime/upstream/src/jsc/bindings/napi.cpp"), "napi.cpp");
    const object = compileObject(b, object_root, "napi.cpp", source);
    cached_napi_object = object;
    return object;
}

pub fn globalGcObject(b: *std.Build, object_root: []const u8) std.Build.LazyPath {
    if (cached_global_gc_object) |object| return object;
    const files = b.addWriteFiles();
    const source = files.addCopyFile(b.path("packages/runtime/src/native/global_gc.cpp"), "global_gc.cpp");
    const object = compileObject(b, object_root, "ZigGlobalObject.cpp", source);
    cached_global_gc_object = object;
    return object;
}

pub fn registryObject(b: *std.Build, object_root: []const u8) std.Build.LazyPath {
    if (cached_registry_object) |object| return object;
    const output = nativeModules(b, object_root);
    const object = compileObject(b, object_root, "UnifiedSource-src_jsc_bindings-1.cpp", output.path(b, "HomeInternalModuleRegistry.cpp"));
    cached_registry_object = object;
    return object;
}

/// Rebuild ScriptExecutionContext from Home so worker shutdown can close the
/// identifier registry before disposing queued C++ tasks. The Home unity
/// wrapper preserves every other implementation from Bun's pinned unit.
pub fn scriptExecutionContextObject(b: *std.Build, object_root: []const u8) std.Build.LazyPath {
    if (cached_script_execution_context_object) |object| return object;
    const io = std.Io.Threaded.global_single_threaded.io();
    const build_root = std.fs.path.dirname(object_root) orelse @panic("invalid native object root");
    const external_path = b.fmt("{s}/unified/UnifiedSource-src_jsc_bindings-4.cpp", .{build_root});
    const external = std.Io.Dir.cwd().readFileAlloc(io, external_path, b.allocator, .limited(1024 * 1024)) catch |err|
        std.debug.panic("cannot read native unified source {s}: {s}", .{ external_path, @errorName(err) });
    defer b.allocator.free(external);
    const wrapper_path = b.root.joinString(b.allocator, "packages/runtime/src/native/HomeScriptExecutionContext.cpp") catch @panic("OOM");
    const wrapper = std.Io.Dir.cwd().readFileAlloc(io, wrapper_path, b.allocator, .limited(1024 * 1024)) catch |err|
        std.debug.panic("cannot read Home unified source {s}: {s}", .{ wrapper_path, @errorName(err) });
    defer b.allocator.free(wrapper);
    if (!unityIncludeBasenamesMatch(external, wrapper)) {
        std.debug.panic("HomeScriptExecutionContext.cpp include order drifted from {s}", .{external_path});
    }

    const files = b.addWriteFiles();
    _ = files.addCopyFile(b.path("packages/runtime/upstream/src/jsc/bindings/ScriptExecutionContext.cpp"), "ScriptExecutionContext.cpp");
    const source = files.addCopyFile(b.path("packages/runtime/src/native/HomeScriptExecutionContext.cpp"), "HomeScriptExecutionContext.cpp");
    const object = compileObject(b, object_root, "UnifiedSource-src_jsc_bindings-4.cpp", source);
    cached_script_execution_context_object = object;
    return object;
}

fn nextUnityInclude(source: []const u8, cursor: *usize) ?[]const u8 {
    while (cursor.* < source.len) {
        const line_end = std.mem.indexOfScalarPos(u8, source, cursor.*, '\n') orelse source.len;
        const line = std.mem.trim(u8, source[cursor.*..line_end], " \t\r");
        cursor.* = @min(line_end + 1, source.len);
        if (!std.mem.startsWith(u8, line, "#include \"") or !std.mem.endsWith(u8, line, "\"")) continue;
        return line[10 .. line.len - 1];
    }
    return null;
}

fn unityIncludeBasenamesMatch(expected: []const u8, actual: []const u8) bool {
    var expected_cursor: usize = 0;
    var actual_cursor: usize = 0;
    while (true) {
        const expected_include = nextUnityInclude(expected, &expected_cursor);
        const actual_include = nextUnityInclude(actual, &actual_cursor);
        if (expected_include == null or actual_include == null)
            return expected_include == null and actual_include == null;
        if (!std.mem.eql(u8, std.fs.path.basename(expected_include.?), std.fs.path.basename(actual_include.?)))
            return false;
    }
}

test "owned ScriptExecutionContext unity wrapper preserves sibling includes" {
    const external =
        \\#include "../../../src/jsc/bindings/ScriptExecutionContext.cpp"
        \\#include "../../../src/jsc/bindings/Serialization.cpp"
    ;
    const owned =
        \\// Home replacement
        \\#include "ScriptExecutionContext.cpp"
        \\#include "Serialization.cpp"
    ;
    try std.testing.expect(unityIncludeBasenamesMatch(external, owned));
    try std.testing.expect(!unityIncludeBasenamesMatch(external, "#include \"ScriptExecutionContext.cpp\"\n"));
    try std.testing.expect(!unityIncludeBasenamesMatch(external, "#include \"Serialization.cpp\"\n#include \"ScriptExecutionContext.cpp\"\n"));
}

pub fn messagePortObject(b: *std.Build, object_root: []const u8) std.Build.LazyPath {
    if (cached_message_port_object) |object| return object;
    const output = nativeModules(b, object_root);
    const object = compileObject(b, object_root, "UnifiedSource-src_jsc_bindings_webcore-3.cpp", output.path(b, "HomeMessagePort.cpp"));
    cached_message_port_object = object;
    return object;
}

pub fn messagePortPipeObject(b: *std.Build, object_root: []const u8) std.Build.LazyPath {
    if (cached_message_port_pipe_object) |object| return object;
    const output = nativeModules(b, object_root);
    const object = compileObject(b, object_root, "UnifiedSource-src_jsc_bindings_webcore-4.cpp", output.path(b, "HomeMessagePortPipe.cpp"));
    cached_message_port_pipe_object = object;
    return object;
}

pub fn workerObject(b: *std.Build, object_root: []const u8) std.Build.LazyPath {
    if (cached_worker_object) |object| return object;
    const output = nativeModules(b, object_root);
    const object = compileObject(b, object_root, "UnifiedSource-src_jsc_bindings_webcore-5.cpp", output.path(b, "HomeWorker.cpp"));
    cached_worker_object = object;
    return object;
}

pub fn workerScopeObject(b: *std.Build, object_root: []const u8) std.Build.LazyPath {
    if (cached_worker_scope_object) |object| return object;
    const output = nativeModules(b, object_root);
    const object = compileObject(b, object_root, "UnifiedSource-src_jsc_bindings-0.cpp", output.path(b, "HomeBunWorkerGlobalScope.cpp"));
    cached_worker_scope_object = object;
    return object;
}

pub fn jsMessagePortObject(b: *std.Build, object_root: []const u8) std.Build.LazyPath {
    if (cached_js_message_port_object) |object| return object;
    const output = nativeModules(b, object_root);
    const object = compileObject(b, object_root, "UnifiedSource-src_jsc_bindings_webcore-2.cpp", output.path(b, "HomeJSMessagePort.cpp"));
    cached_js_message_port_object = object;
    return object;
}

pub fn jsAbortSignalObject(b: *std.Build, object_root: []const u8) std.Build.LazyPath {
    if (cached_js_abort_signal_object) |object| return object;
    const output = nativeModules(b, object_root);
    const object = compileObject(b, object_root, "UnifiedSource-src_jsc_bindings_webcore-1.cpp", output.path(b, "HomeJSAbortSignalCustom.cpp"));
    cached_js_abort_signal_object = object;
    return object;
}

/// Compile the uWebSockets C ABI from Home's pinned source so parser fixes in
/// the mirrored bun-uws headers are part of the executable rather than dead
/// reference code beside Bun's external object.
pub fn uwsObject(b: *std.Build, object_root: []const u8) std.Build.LazyPath {
    if (cached_uws_object) |object| return object;
    const source = b.path("packages/runtime/upstream/src/uws_sys/HomeUws.cpp");
    const object = compileObject(b, object_root, "UnifiedSource-src_uws_sys-0.cpp", source);
    cached_uws_object = object;
    return object;
}

fn nativeModules(b: *std.Build, object_root: []const u8) std.Build.LazyPath {
    if (cached_native_modules) |output| return output;
    const build_root = std.fs.path.dirname(object_root) orelse @panic("invalid native object root");
    const bundler = b.findProgram(.{ .names = &.{"bun"} }) orelse @panic("Home builtin generation requires Bun at build time");
    const generate = b.addSystemCommand(&.{bundler});
    generate.addFileInput(.{ .cwd_relative = bundler });
    generate.setName("generate Home native builtin modules");
    generate.addFileArg(b.path("build-support/bundle-native-modules.ts"));
    generate.addArg(build_root);
    const output = generate.addOutputDirectoryArg2("native-modules", .{ .make_absolute = true });
    for ([_][]const u8{
        "build-support/native_module_abi.ts",
        "packages/runtime/src/jsc/internal-stream-wrap.js",
        "packages/runtime/upstream/src/codegen/builtin-parser.ts",
        "packages/runtime/upstream/src/codegen/client-js.ts",
        "packages/runtime/upstream/src/codegen/generate-js2native.ts",
        "packages/runtime/upstream/src/codegen/helpers.ts",
        "packages/runtime/upstream/src/codegen/internal-module-registry-scanner.ts",
        "packages/runtime/upstream/src/codegen/replacements.ts",
        "packages/runtime/upstream/src/api/schema.js",
        "packages/runtime/upstream/src/jsc/bindings/ErrorCode.ts",
        "packages/runtime/upstream/src/jsc/bindings/ErrorCode.cpp",
        "packages/runtime/upstream/src/jsc/bindings/js_classes.ts",
        "packages/runtime/upstream/src/jsc/bindings/InternalModuleRegistry.cpp",
        "packages/runtime/upstream/src/jsc/bindings/EventLoopTaskNoContext.cpp",
        "packages/runtime/src/native/H2HeadersMaterializer.cpp",
        "packages/runtime/upstream/src/jsc/bindings/BunWorkerGlobalScope.cpp",
        "packages/runtime/upstream/src/jsc/bindings/BunWorkerGlobalScope.h",
        "packages/runtime/upstream/src/jsc/bindings/BunAnalyzeTranspiledModule.cpp",
        "packages/runtime/upstream/src/jsc/bindings/BunAnalyzeTranspiledModule.h",
        "packages/runtime/upstream/src/jsc/bindings/webcore/JSAbortSignalCustom.cpp",
        "packages/runtime/upstream/src/jsc/bindings/webcore/AbortSignal.h",
        "packages/runtime/upstream/src/jsc/bindings/webcore/JSMessagePort.cpp",
        "packages/runtime/upstream/src/jsc/bindings/webcore/JSMessagePort.h",
        "packages/runtime/upstream/src/jsc/bindings/webcore/MessagePort.cpp",
        "packages/runtime/upstream/src/jsc/bindings/webcore/MessagePort.h",
        "packages/runtime/upstream/src/jsc/bindings/webcore/MessagePortPipe.cpp",
        "packages/runtime/upstream/src/jsc/bindings/webcore/MessagePortPipe.h",
        "packages/runtime/upstream/src/jsc/bindings/webcore/Worker.cpp",
        "packages/runtime/upstream/src/jsc/bindings/webcore/Worker.h",
        "packages/runtime/upstream/src/jsc/bindings/webcore/HomeMessagePortLifecycle.h",
        "packages/runtime/upstream/src/jsc/bindings/webcore/HomeWorkerSnapshots.h",
        "packages/runtime/upstream/src/jsc/bindings/webcore/JSWorker.cpp",
        "packages/runtime/upstream/src/jsc/bindings/webcore/JSWorker.h",
        "packages/runtime/upstream/src/jsc/modules/_NativeModule.h",
        "packages/runtime/upstream/src/js/node/url.ts",
        "packages/runtime/upstream/src/js/node/worker_threads.ts",
        "packages/runtime/upstream/src/js/node/querystring.ts",
        "packages/runtime/upstream/src/js/internal/url.ts",
        "packages/runtime/upstream/src/js/internal/validators.ts",
    }) |input| generate.addFileInput(b.path(input));
    for ([_][]const u8{
        "codegen/InternalModuleRegistry+enum.h",
        "codegen/InternalModuleRegistryConstants.h",
        "js/internal-for-testing.js",
        "codegen/GeneratedJS2Native.h",
        "codegen/ErrorCode+List.h",
        "unified/UnifiedSource-src_jsc_bindings-1.cpp",
        "unified/UnifiedSource-src_jsc_bindings-0.cpp",
        "unified/UnifiedSource-src_jsc_bindings_webcore-1.cpp",
        "unified/UnifiedSource-src_jsc_bindings_webcore-2.cpp",
        "unified/UnifiedSource-src_jsc_bindings_webcore-3.cpp",
        "unified/UnifiedSource-src_jsc_bindings_webcore-4.cpp",
        "unified/UnifiedSource-src_jsc_bindings_webcore-5.cpp",
    }) |input| generate.addFileInput(.{ .cwd_relative = b.fmt("{s}/{s}", .{ build_root, input }) });
    // Header comparisons are generation inputs, not merely clang inputs: a
    // changed external ABI must invalidate generation before any owned object
    // can be linked. Resolve against the selected unified source, including
    // absolute includes used by isolated build fixtures.
    const io = std.Io.Threaded.global_single_threaded.io();
    for ([_][3][]const u8{
        .{ "UnifiedSource-src_jsc_bindings_webcore-1.cpp", "JSAbortSignalCustom.cpp", "AbortSignal.h" },
        .{ "UnifiedSource-src_jsc_bindings_webcore-3.cpp", "MessagePort.cpp", "MessagePort.h" },
        .{ "UnifiedSource-src_jsc_bindings_webcore-3.cpp", "JSWorker.cpp", "JSWorker.h" },
        .{ "UnifiedSource-src_jsc_bindings_webcore-4.cpp", "MessagePortPipe.cpp", "MessagePortPipe.h" },
        .{ "UnifiedSource-src_jsc_bindings_webcore-5.cpp", "Worker.cpp", "Worker.h" },
        .{ "UnifiedSource-src_jsc_bindings-0.cpp", "BunWorkerGlobalScope.cpp", "BunWorkerGlobalScope.h" },
        .{ "UnifiedSource-src_jsc_bindings-0.cpp", "BunAnalyzeTranspiledModule.cpp", "BunAnalyzeTranspiledModule.h" },
        .{ "UnifiedSource-src_jsc_bindings_webcore-2.cpp", "JSMessagePort.cpp", "JSMessagePort.h" },
    }) |entry| {
        const unified_path = b.fmt("{s}/unified/{s}", .{ build_root, entry[0] });
        const unified = std.Io.Dir.cwd().readFileAlloc(io, unified_path, b.allocator, .limited(1024 * 1024)) catch |err|
            std.debug.panic("cannot read native unified source {s}: {s}", .{ unified_path, @errorName(err) });
        defer b.allocator.free(unified);
        const source = unifiedSourcePath(b.allocator, unified, unified_path, entry[1]) catch |err|
            std.debug.panic("invalid native unified source {s}: {s}", .{ unified_path, @errorName(err) });
        defer b.allocator.free(source);
        const header = b.fmt("{s}/{s}", .{ std.fs.path.dirname(source).?, entry[2] });
        generate.addFileInput(.{ .cwd_relative = header });
    }
    cached_native_modules = output;
    return output;
}

fn unifiedSourcePath(allocator: std.mem.Allocator, unified: []const u8, unified_path: []const u8, basename: []const u8) ![]const u8 {
    var selected: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, unified, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (!std.mem.startsWith(u8, trimmed, "#include \"") or !std.mem.endsWith(u8, trimmed, "\"")) continue;
        const included = trimmed[10 .. trimmed.len - 1];
        if (!std.mem.eql(u8, std.fs.path.basename(included), basename)) continue;
        if (selected != null) return error.DuplicateOwnedSource;
        selected = included;
    }
    const included = selected orelse return error.MissingOwnedSource;
    return std.fs.path.resolve(allocator, &.{ std.fs.path.dirname(unified_path) orelse return error.InvalidUnifiedPath, included });
}

test "owned unified source resolves selected relative and absolute header roots" {
    const relative = try unifiedSourcePath(std.testing.allocator, "#include \"../../../src/OtherMessagePortPipe.cpp\"\n#include \"../../../src/webcore/MessagePortPipe.cpp\"\n", "/bun/build/release/unified/unit.cpp", "MessagePortPipe.cpp");
    defer std.testing.allocator.free(relative);
    try std.testing.expectEqualStrings("/bun/src/webcore/MessagePortPipe.cpp", relative);
    const absolute = try unifiedSourcePath(std.testing.allocator, "#include \"/fixture/webcore/MessagePort.cpp\"\r\n", "/fixture/build/unified/unit.cpp", "MessagePort.cpp");
    defer std.testing.allocator.free(absolute);
    try std.testing.expectEqualStrings("/fixture/webcore/MessagePort.cpp", absolute);
    try std.testing.expectError(error.MissingOwnedSource, unifiedSourcePath(std.testing.allocator, "#include \"OtherMessagePort.cpp\"\n", "/build/unit.cpp", "MessagePort.cpp"));
    try std.testing.expectError(error.DuplicateOwnedSource, unifiedSourcePath(std.testing.allocator, "#include \"MessagePort.cpp\"\n#include \"other/MessagePort.cpp\"\n", "/build/unit.cpp", "MessagePort.cpp"));
}

fn compileObject(b: *std.Build, object_root: []const u8, basename: []const u8, source: std.Build.LazyPath) std.Build.LazyPath {
    const io = std.Io.Threaded.global_single_threaded.io();
    const build_root = std.fs.path.dirname(object_root) orelse
        std.debug.panic("invalid HOME_BUN_OBJ_ROOT: {s}", .{object_root});
    const database_path = b.fmt("{s}/compile_commands.json", .{build_root});
    const database = std.Io.Dir.cwd().readFileAlloc(io, database_path, b.allocator, .limited(16 * 1024 * 1024)) catch |err|
        std.debug.panic("Home-owned {s} requires {s}: {s}", .{ basename, database_path, @errorName(err) });
    defer b.allocator.free(database);
    const parsed = std.json.parseFromSlice([]CompileCommand, b.allocator, database, .{
        .ignore_unknown_fields = true,
    }) catch |err| std.debug.panic("invalid native compile database {s}: {s}", .{ database_path, @errorName(err) });
    defer parsed.deinit();

    const command = findCommand(parsed.value, basename) orelse
        std.debug.panic("no {s} command in {s}", .{ basename, database_path });
    if (command.arguments.len == 0) std.debug.panic("empty native compile command in {s}", .{database_path});
    if (std.mem.eql(u8, basename, "UnifiedSource-src_jsc_bindings-1.cpp") and hasDynamicBuiltinLoading(command.arguments)) {
        std.debug.panic("Home-owned builtin modules require embedded native artifacts; BUN_DYNAMIC_JS_LOAD_PATH would bypass Home's generated literals", .{});
    }
    const process_command = findCommand(parsed.value, "BunProcess.cpp") orelse
        std.debug.panic("no BunProcess.cpp command for native header root in {s}", .{database_path});

    // Copy only the implementation into the build cache. Its quoted includes
    // must resolve against the ABI-matched upstream header set, not another
    // version of those headers beside Home's mirrored source.
    const compile = b.addSystemCommand(&.{command.arguments[0]});
    compile.addFileInput(.{ .cwd_relative = command.arguments[0] });
    compile.setName(b.fmt("compile Home {s} binding", .{basename}));
    compile.setCwd(.{ .cwd_relative = command.directory });
    compile.addFileInput(.{ .cwd_relative = database_path });
    if (std.mem.eql(u8, basename, "napi.cpp")) {
        // The plain-context corpus adapter has a separate environment ABI.
        // Its public entry points dispatch real NapiEnv values here before
        // touching the adapter layout. Do not weaken either implementation.
        for ([_][]const u8{
            "napi_create_external", "napi_create_function",    "napi_create_object",
            "napi_get_cb_info",     "napi_get_value_bool",     "napi_get_value_external",
            "napi_module_register", "napi_set_named_property", "napi_throw_error",
        }) |symbol| compile.addArg(b.fmt("-D{s}=HomeNative_{s}", .{ symbol, symbol }));
    }

    var i: usize = 1;
    while (i < command.arguments.len) : (i += 1) {
        const arg = command.arguments[i];
        if (std.mem.eql(u8, arg, command.file) or std.mem.eql(u8, arg, "-c")) continue;
        if (isOutputOption(arg)) {
            if (i + 1 >= command.arguments.len) std.debug.panic("missing value after {s} in native compile command", .{arg});
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "-MD") or std.mem.eql(u8, arg, "-MMD") or std.mem.eql(u8, arg, "-MP")) continue;
        if (std.mem.eql(u8, arg, "-include-pch")) {
            if (i + 1 >= command.arguments.len) std.debug.panic("missing native precompiled header path", .{});
            i += 1;
            // A saved PCH can belong to a different compiler version than the
            // compile database. Parse its source header instead; the depfile
            // below tracks all transitively included headers for caching.
            compile.addArg("-include");
            const source_dir = std.fs.path.dirname(process_command.file) orelse
                std.debug.panic("BunProcess source path has no directory", .{});
            compile.addFileArg2(.{ .cwd_relative = b.fmt("{s}/root-pch.h", .{source_dir}) }, .{ .make_absolute = true });
            continue;
        }
        const normalized = normalizeDefine(b.allocator, arg) catch @panic("OOM");
        defer b.allocator.free(normalized);
        compile.addArg(normalized);
    }
    compile.addArg("-c");
    // Depfile paths are consumed by Zig from Home's build directory, whereas
    // clang runs in the upstream build directory. Emit absolute inputs so
    // both agree on their meaning.
    compile.addFileArg2(source, .{ .make_absolute = true });
    compile.addArg("-o");
    const object = compile.addOutputFileArg2(b.fmt("{s}.o", .{basename}), .{ .make_absolute = true });
    compile.addArgs(&.{ "-MD", "-MF" });
    _ = compile.addDepFileOutputArg2(b.fmt("{s}.d", .{basename}), .{ .make_absolute = true });
    return object;
}

fn findCommand(commands: []const CompileCommand, basename: []const u8) ?CompileCommand {
    for (commands) |command| {
        if (std.mem.eql(u8, std.fs.path.basename(command.file), basename)) return command;
    }
    return null;
}

fn isOutputOption(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "-MF") or
        std.mem.eql(u8, arg, "-MT") or std.mem.eql(u8, arg, "-MQ");
}

fn hasDynamicBuiltinLoading(arguments: []const []const u8) bool {
    for (arguments, 0..) |arg, i| {
        const define = if (std.mem.startsWith(u8, arg, "-D")) arg[2..] else if (i > 0 and std.mem.eql(u8, arguments[i - 1], "-D")) arg else continue;
        if (std.mem.eql(u8, define, "BUN_DYNAMIC_JS_LOAD_PATH") or std.mem.startsWith(u8, define, "BUN_DYNAMIC_JS_LOAD_PATH=")) return true;
    }
    return false;
}

test "owned builtin binding rejects dynamic external source loading" {
    try std.testing.expect(hasDynamicBuiltinLoading(&.{"-DBUN_DYNAMIC_JS_LOAD_PATH=\"/external/js\""}));
    try std.testing.expect(hasDynamicBuiltinLoading(&.{ "-D", "BUN_DYNAMIC_JS_LOAD_PATH=/external/js" }));
    try std.testing.expect(hasDynamicBuiltinLoading(&.{"-DBUN_DYNAMIC_JS_LOAD_PATH"}));
    try std.testing.expect(!hasDynamicBuiltinLoading(&.{ "-DNDEBUG", "-DBUN_DYNAMIC_JS_LOAD_PATH_OTHER=1" }));
}

/// Bun's compile database can retain shell escaping around string-valued
/// definitions. Run executes argv directly (no shell), so remove only the
/// backslashes immediately preceding quotes in -D arguments.
fn normalizeDefine(allocator: std.mem.Allocator, arg: []const u8) ![]u8 {
    if (!std.mem.startsWith(u8, arg, "-D")) return allocator.dupe(u8, arg);
    var normalized: std.ArrayList(u8) = .empty;
    errdefer normalized.deinit(allocator);
    var i: usize = 0;
    while (i < arg.len) {
        if (arg[i] == '\\') {
            var end = i;
            while (end < arg.len and arg[end] == '\\') : (end += 1) {}
            if (end < arg.len and arg[end] == '"') {
                try normalized.append(allocator, '"');
                i = end + 1;
                continue;
            }
        }
        try normalized.append(allocator, arg[i]);
        i += 1;
    }
    return normalized.toOwnedSlice(allocator);
}

test "native binding selects only the process implementation" {
    const commands = [_]CompileCommand{
        .{ .directory = "/build", .file = "/src/OtherBunProcess.cpp", .arguments = &.{} },
        .{ .directory = "/build", .file = "/src/BunProcess.cpp", .arguments = &.{"clang++"} },
    };
    try std.testing.expectEqualStrings("/src/BunProcess.cpp", findCommand(&commands, "BunProcess.cpp").?.file);
    try std.testing.expect(findCommand(commands[0..1], "BunProcess.cpp") == null);
    try std.testing.expect(isOutputOption("-o"));
    try std.testing.expect(isOutputOption("-MF"));
    try std.testing.expect(!isOutputOption("-O3"));
}

test "native binding normalizes shell-escaped definitions without changing paths" {
    const cases = .{
        .{ "-DVERSION=\\\"1.2.3\\\"", "-DVERSION=\"1.2.3\"" },
        .{ "-DVERSION=\\\\\\\"1.2.3\\\\\\\"", "-DVERSION=\"1.2.3\"" },
        .{ "-DVERSION=\"1.2.3\"", "-DVERSION=\"1.2.3\"" },
        .{ "-DCOUNT=147", "-DCOUNT=147" },
        .{ "-IC:\\headers\\include", "-IC:\\headers\\include" },
        .{ "-DPATH=C:\\headers", "-DPATH=C:\\headers" },
    };
    inline for (cases) |pair| {
        const result = try normalizeDefine(std.testing.allocator, pair[0]);
        defer std.testing.allocator.free(result);
        try std.testing.expectEqualStrings(pair[1], result);
    }
}
