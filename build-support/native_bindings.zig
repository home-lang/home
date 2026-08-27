const std = @import("std");

const CompileCommand = struct {
    directory: []const u8,
    file: []const u8,
    arguments: []const []const u8,
};

var cached_process_object: ?std.Build.LazyPath = null;
var cached_registry_object: ?std.Build.LazyPath = null;

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

pub fn registryObject(b: *std.Build, object_root: []const u8) std.Build.LazyPath {
    if (cached_registry_object) |object| return object;
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
        "packages/runtime/upstream/src/codegen/builtin-parser.ts",
        "packages/runtime/upstream/src/codegen/client-js.ts",
        "packages/runtime/upstream/src/codegen/generate-js2native.ts",
        "packages/runtime/upstream/src/codegen/helpers.ts",
        "packages/runtime/upstream/src/codegen/internal-module-registry-scanner.ts",
        "packages/runtime/upstream/src/codegen/replacements.ts",
        "packages/runtime/upstream/src/api/schema.js",
        "packages/runtime/upstream/src/jsc/bindings/ErrorCode.ts",
        "packages/runtime/upstream/src/jsc/bindings/js_classes.ts",
        "packages/runtime/upstream/src/jsc/bindings/InternalModuleRegistry.cpp",
        "packages/runtime/upstream/src/jsc/modules/_NativeModule.h",
        "packages/runtime/upstream/src/js/node/url.ts",
        "packages/runtime/upstream/src/js/node/querystring.ts",
        "packages/runtime/upstream/src/js/internal/url.ts",
        "packages/runtime/upstream/src/js/internal/validators.ts",
    }) |input| generate.addFileInput(b.path(input));
    for ([_][]const u8{
        "codegen/InternalModuleRegistry+enum.h",
        "codegen/InternalModuleRegistryConstants.h",
        "codegen/GeneratedJS2Native.h",
        "codegen/ErrorCode+List.h",
        "unified/UnifiedSource-src_jsc_bindings-1.cpp",
    }) |input| generate.addFileInput(.{ .cwd_relative = b.fmt("{s}/{s}", .{ build_root, input }) });
    const object = compileObject(b, object_root, "UnifiedSource-src_jsc_bindings-1.cpp", output.path(b, "HomeInternalModuleRegistry.cpp"));
    cached_registry_object = object;
    return object;
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
