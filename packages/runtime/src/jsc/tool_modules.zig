//! CommonJS module loading for Home repository tools.
//!
//! Resolution and TypeScript emission stay in Home. JavaScript glue owns the
//! CommonJS cache and cycle behavior so both zig-js and JSC execute identical
//! emitted sources without inheriting Node or Bun at runtime.

const std = @import("std");
const bun = @import("bun");
const callback = @import("callback.zig");
const evaluate = @import("evaluate.zig");
const extern_fns = @import("extern_fns.zig");
const opaques = @import("opaques.zig");
const ts_driver = @import("ts_driver");
const hir_mod = @import("hir");
const package_exports = @import("tool_package_exports.zig");

const JSValue = opaques.JSValue;
const JSContextRef = opaques.JSContextRef;
const JSObject = opaques.JSObject;
const JSGlobalObject = opaques.JSGlobalObject;
const g_io = std.Io.Threaded.global_single_threaded.io();

// Native filenames participate in lookup, but never in source evaluation.
const extensions = [_][]const u8{ ".ts", ".tsx", ".mts", ".cts", ".js", ".mjs", ".cjs", ".json", ".node" };

fn valueToOwnedUtf8(ctx: *JSContextRef, value: *JSValue, allocator: std.mem.Allocator) ?[]u8 {
    const string = extern_fns.JSValueToStringCopy(ctx, value, null) orelse return null;
    defer extern_fns.JSStringRelease(string);
    const capacity = extern_fns.JSStringGetLength(string) * 4 + 1;
    const buffer = allocator.alloc(u8, capacity) catch return null;
    defer allocator.free(buffer);
    const written = extern_fns.JSStringGetUTF8CString(string, buffer.ptr, buffer.len);
    const end = if (written > 0) written - 1 else 0;
    return allocator.dupe(u8, buffer[0..end]) catch null;
}

fn stringValue(ctx: *JSContextRef, text: []const u8) ?*JSValue {
    const allocator = std.heap.smp_allocator;
    const text_z = bun.dupeZ(allocator, u8, text) catch return null;
    defer allocator.free(text_z);
    const string = extern_fns.JSStringCreateWithUTF8CString(text_z.ptr) orelse return null;
    defer extern_fns.JSStringRelease(string);
    return extern_fns.JSValueMakeString(ctx, string);
}

fn setProperty(ctx: *JSContextRef, object: *JSObject, name: []const u8, value: ?*JSValue) void {
    const allocator = std.heap.page_allocator;
    const name_z = bun.dupeZ(allocator, u8, name) catch return;
    defer allocator.free(name_z);
    const string = extern_fns.JSStringCreateWithUTF8CString(name_z.ptr) orelse return;
    defer extern_fns.JSStringRelease(string);
    extern_fns.JSObjectSetProperty(ctx, object, string, value, 0, null);
}

fn isFile(path: []const u8) bool {
    const stat = std.Io.Dir.cwd().statFile(g_io, path, .{}) catch return false;
    return stat.kind == .file;
}

fn isDirectory(path: []const u8) bool {
    var dir = std.Io.Dir.cwd().openDir(g_io, path, .{}) catch return false;
    dir.close(g_io);
    return true;
}

fn resolvedFile(allocator: std.mem.Allocator, path: []const u8) ?[]u8 {
    if (!isFile(path)) return null;
    const canonical = std.Io.Dir.cwd().realPathFileAlloc(g_io, path, allocator) catch return null;
    defer allocator.free(canonical);
    return allocator.dupe(u8, canonical) catch null;
}

fn tryWithExtensions(allocator: std.mem.Allocator, base: []const u8) ?[]u8 {
    if (resolvedFile(allocator, base)) |path| return path;
    // CommonJS LOAD_AS_FILE appends supported source suffixes even when the
    // requested basename contains dots (e.g. module.compiled.js). Keep an
    // existing exact filename first, and preserve Home's extension priority.
    // https://nodejs.org/api/modules.html#all-together
    for (extensions) |extension| {
        const candidate = std.mem.concat(allocator, u8, &.{ base, extension }) catch return null;
        defer allocator.free(candidate);
        if (resolvedFile(allocator, candidate)) |path| return path;
    }
    return null;
}

fn packageMain(allocator: std.mem.Allocator, directory: []const u8) ?[]u8 {
    const package_path = std.fs.path.join(allocator, &.{ directory, "package.json" }) catch return null;
    defer allocator.free(package_path);
    const source = std.Io.Dir.cwd().readFileAlloc(g_io, package_path, allocator, .limited(1024 * 1024)) catch return null;
    defer allocator.free(source);
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, source, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const main_value = parsed.value.object.get("main") orelse parsed.value.object.get("module") orelse return null;
    if (main_value != .string or main_value.string.len == 0) return null;
    return std.fs.path.join(allocator, &.{ directory, main_value.string }) catch null;
}

fn tryPath(allocator: std.mem.Allocator, base: []const u8) ?[]u8 {
    if (tryWithExtensions(allocator, base)) |path| return path;
    if (!isDirectory(base)) return null;
    if (packageMain(allocator, base)) |main_path| {
        defer allocator.free(main_path);
        if (!std.mem.eql(u8, main_path, base)) {
            if (tryWithExtensions(allocator, main_path)) |path| return path;
            if (isDirectory(main_path)) {
                for (extensions) |extension| {
                    const index_name = std.mem.concat(allocator, u8, &.{ "index", extension }) catch return null;
                    defer allocator.free(index_name);
                    const candidate = std.fs.path.join(allocator, &.{ main_path, index_name }) catch return null;
                    defer allocator.free(candidate);
                    if (resolvedFile(allocator, candidate)) |path| return path;
                }
            }
        }
    }
    for (extensions) |extension| {
        const index_name = std.mem.concat(allocator, u8, &.{ "index", extension }) catch return null;
        defer allocator.free(index_name);
        const candidate = std.fs.path.join(allocator, &.{ base, index_name }) catch return null;
        defer allocator.free(candidate);
        if (resolvedFile(allocator, candidate)) |path| return path;
    }
    return null;
}

fn resolvePackageImport(allocator: std.mem.Allocator, specifier: []const u8, parent_dir: []const u8) ?[]u8 {
    if (specifier.len < 2 or specifier[1] == '/') return null;
    var search_dir = std.fs.path.resolve(allocator, &.{parent_dir}) catch return null;
    defer allocator.free(search_dir);
    while (true) {
        // Node's LOOKUP_PACKAGE_SCOPE stops at the nearest package.json and
        // never inherits a repository's private imports through node_modules.
        // https://nodejs.org/api/packages.html#subpath-imports
        if (std.mem.eql(u8, std.fs.path.basename(search_dir), "node_modules")) return null;
        const package_path = std.fs.path.join(allocator, &.{ search_dir, "package.json" }) catch return null;
        defer allocator.free(package_path);
        if (isFile(package_path)) {
            const source = std.Io.Dir.cwd().readFileAlloc(g_io, package_path, allocator, .limited(1024 * 1024)) catch return null;
            defer allocator.free(source);
            const parsed = std.json.parseFromSlice(std.json.Value, allocator, source, .{}) catch return null;
            defer parsed.deinit();
            if (parsed.value != .object) return null;
            const imports = parsed.value.object.get("imports") orelse return null;
            if (imports != .object) return null;
            const target = imports.object.get(specifier) orelse return null;
            // This host currently supports exact, unconditional relative file
            // targets. Conditions, patterns and external targets stay refused
            // until their actual resolver contracts are implemented.
            if (target != .string or !std.mem.startsWith(u8, target.string, "./")) return null;
            const relative = target.string[2..];
            if (relative.len == 0 or std.mem.findAny(u8, relative, "\\%?#") != null) return null;
            var segments = std.mem.splitScalar(u8, relative, '/');
            while (segments.next()) |segment| {
                if (std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..") or
                    std.mem.eql(u8, segment, "node_modules")) return null;
            }
            const candidate = std.fs.path.join(allocator, &.{ search_dir, relative }) catch return null;
            defer allocator.free(candidate);
            // Import targets are exact files: no extension or directory-main
            // fallback may turn a missing/blocked target into another module.
            return resolvedFile(allocator, candidate);
        }
        const next = std.fs.path.dirname(search_dir) orelse return null;
        if (std.mem.eql(u8, next, search_dir)) return null;
        const replacement = allocator.dupe(u8, next) catch return null;
        allocator.free(search_dir);
        search_dir = replacement;
    }
}

const PackageExport = union(enum) { absent, path: []u8 };

fn packageExport(allocator: std.mem.Allocator, directory: []const u8, subpath: []const u8, mode: package_exports.Mode, conditions: []const []const u8, self_name: ?[]const u8) !PackageExport {
    const package_path = try std.fs.path.join(allocator, &.{ directory, "package.json" });
    defer allocator.free(package_path);
    const source = std.Io.Dir.cwd().readFileAlloc(g_io, package_path, allocator, .limited(1024 * 1024)) catch |err| {
        if (err == error.FileNotFound) return .absent;
        return error.InvalidPackageConfig;
    };
    defer allocator.free(source);
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, source, .{}) catch return error.InvalidPackageConfig;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidPackageConfig;
    if (self_name) |expected| {
        const name = parsed.value.object.get("name") orelse return .absent;
        if (name != .string or !std.mem.eql(u8, name.string, expected)) return .absent;
    }
    const exports = parsed.value.object.get("exports") orelse return .absent;
    // Node's package reader ignores null/primitive fields other than strings.
    // Invalid nested targets still fail PACKAGE_TARGET_RESOLVE.
    if (exports != .string and exports != .object and exports != .array) return .absent;
    const relative = try package_exports.resolveWithConditions(allocator, exports, subpath, mode, conditions);
    defer allocator.free(relative);
    const target = try std.fs.path.join(allocator, &.{ directory, relative });
    defer allocator.free(target);
    // Exports selects an exact file, never extension/index/array fallbacks
    // chosen by filesystem existence. A missing selected target stays failed.
    return .{ .path = resolvedFile(allocator, target) orelse return error.ExportedFileNotFound };
}

fn resolvePackage(allocator: std.mem.Allocator, specifier: []const u8, parent_dir: []const u8, mode: package_exports.Mode, conditions: []const []const u8) !?[]u8 {
    const first_slash = std.mem.findScalar(u8, specifier, '/');
    const name_end = if (specifier[0] == '@') blk: {
        const scope_end = first_slash orelse return error.InvalidModuleSpecifier;
        if (scope_end < 2 or scope_end + 1 == specifier.len) return error.InvalidModuleSpecifier;
        break :blk if (std.mem.findScalar(u8, specifier[scope_end + 1 ..], '/')) |offset| scope_end + 1 + offset else specifier.len;
    } else first_slash orelse specifier.len;
    const name = specifier[0..name_end];
    if (name[0] == '.' or name[name.len - 1] == '/' or std.mem.findAny(u8, name, "\\%") != null) return error.InvalidModuleSpecifier;
    const subpath = if (name_end == specifier.len) try allocator.dupe(u8, ".") else try std.mem.concat(allocator, u8, &.{ ".", specifier[name_end..] });
    defer allocator.free(subpath);
    var search_dir = try std.fs.path.resolve(allocator, &.{parent_dir});
    defer allocator.free(search_dir);
    // PACKAGE_SELF_RESOLVE uses only the nearest package scope and only when
    // its name matches and exports exists. It cannot inherit a parent's name.
    var scope = try allocator.dupe(u8, search_dir);
    defer allocator.free(scope);
    while (!std.mem.eql(u8, std.fs.path.basename(scope), "node_modules")) {
        const manifest = try std.fs.path.join(allocator, &.{ scope, "package.json" });
        defer allocator.free(manifest);
        if (isFile(manifest)) {
            switch (try packageExport(allocator, scope, subpath, mode, conditions, name)) {
                .path => |path| return path,
                .absent => break,
            }
        }
        const next = std.fs.path.dirname(scope) orelse break;
        if (std.mem.eql(u8, next, scope)) break;
        const replacement = try allocator.dupe(u8, next);
        allocator.free(scope);
        scope = replacement;
    }
    while (true) {
        const directory = try std.fs.path.join(allocator, &.{ search_dir, "node_modules", name });
        defer allocator.free(directory);
        if (isDirectory(directory)) {
            switch (try packageExport(allocator, directory, subpath, mode, conditions, null)) {
                .path => |path| return path,
                .absent => {
                    const candidate = try std.fs.path.join(allocator, &.{ search_dir, "node_modules", specifier });
                    defer allocator.free(candidate);
                    return tryPath(allocator, candidate);
                },
            }
        }
        const next = std.fs.path.dirname(search_dir) orelse break;
        if (std.mem.eql(u8, next, search_dir)) break;
        const replacement = try allocator.dupe(u8, next);
        allocator.free(search_dir);
        search_dir = replacement;
    }
    return null;
}

fn resolveModule(allocator: std.mem.Allocator, specifier: []const u8, parent_path: []const u8, mode: package_exports.Mode, conditions: []const []const u8) !?[]u8 {
    if (specifier.len == 0) return null;
    const parent_dir = if (parent_path.len == 0)
        "."
    else
        std.fs.path.dirname(parent_path) orelse ".";
    if (specifier[0] == '#') return resolvePackageImport(allocator, specifier, parent_dir);
    // CommonJS LOAD_AS_DIRECTORY accepts the exact current/parent names too.
    // Keep this require-only; ESM directory imports are a separate contract.
    const dot_directory = mode == .require and
        (std.mem.eql(u8, specifier, ".") or std.mem.eql(u8, specifier, ".."));
    const path_like = dot_directory or std.fs.path.isAbsolute(specifier) or
        std.mem.startsWith(u8, specifier, "./") or
        std.mem.startsWith(u8, specifier, "../");
    if (path_like) {
        const candidate = if (std.fs.path.isAbsolute(specifier))
            allocator.dupe(u8, specifier) catch return null
        else
            std.fs.path.join(allocator, &.{ parent_dir, specifier }) catch return null;
        defer allocator.free(candidate);
        return tryPath(allocator, candidate);
    }

    // Entry paths commonly arrive as repository-relative names rather than
    // `./name`; resolve those before applying package lookup semantics.
    if (parent_path.len == 0) {
        if (tryPath(allocator, specifier)) |path| return path;
    }

    return resolvePackage(allocator, specifier, parent_dir, mode, conditions);
}

// Await belongs to module evaluation only outside a function's body/parameters.
// Inspect HIR ancestry rather than source text (strings, comments and method
// computed names are not function bodies).
fn hasTopLevelAwait(hir: *const hir_mod.Hir) bool {
    for (hir.kinds.items, 0..) |kind, index| {
        const node: hir_mod.NodeId = @intCast(index);
        if (kind != .await_expr and !(kind == .for_of_stmt and hir_mod.forInOf(hir, node).is_await)) continue;
        var child = node;
        var parent = hir.parentOf(child);
        var in_function = false;
        while (parent != hir_mod.none_node_id) : ({
            child = parent;
            parent = hir.parentOf(parent);
        }) {
            switch (hir.kindOf(parent)) {
                .fn_decl, .fn_expr, .arrow_fn => {
                    const function = hir_mod.fnDeclOf(hir, parent);
                    if (child == function.body or hir.kindOf(child) == .parameter) {
                        in_function = true;
                        break;
                    }
                },
                else => {},
            }
        }
        if (!in_function) return true;
    }
    return false;
}

fn emitModule(allocator: std.mem.Allocator, source: []const u8, path: []const u8, meta_binding: *?[]u8, module_binding: *?[]u8, import_binding: *?[]u8, dynamic_binding: *?[]u8, is_esm: *bool, top_await: *bool, static_imports: *?[]u8) ?[]u8 {
    meta_binding.* = null;
    module_binding.* = null;
    import_binding.* = null;
    dynamic_binding.* = null;
    is_esm.* = false;
    top_await.* = false;
    static_imports.* = null;
    if (std.mem.eql(u8, std.fs.path.extension(path), ".json"))
        return allocator.dupe(u8, source) catch null;
    const is_tsx = std.mem.endsWith(u8, path, ".tsx");
    var options: ts_driver.CompileOptions = .{
        .continue_on_error = false,
        .is_tsx = is_tsx,
        .jsx_option_present = is_tsx,
        .importer_path = path,
        .emit = .{ .module_kind = .commonjs },
    };
    var compilation = ts_driver.prepareSource(allocator, source, options) catch return null;
    defer {
        compilation.deinit();
        allocator.destroy(compilation);
    }
    var imports: std.ArrayListUnmanaged([]const u8) = .empty;
    defer imports.deinit(allocator);
    top_await.* = hasTopLevelAwait(&compilation.hir);
    const extension = std.fs.path.extension(path);
    is_esm.* = std.mem.eql(u8, extension, ".mjs") or std.mem.eql(u8, extension, ".mts") or
        (top_await.* and !std.mem.eql(u8, extension, ".cjs") and !std.mem.eql(u8, extension, ".cts"));
    if (compilation.root != hir_mod.none_node_id) {
        for (hir_mod.blockStmts(&compilation.hir, compilation.root)) |statement| {
            if (compilation.hir.kindOf(statement) == .import_decl) {
                const imp = hir_mod.importOf(&compilation.hir, statement);
                if (imp.is_require_equals) continue;
                is_esm.* = true;
                if (!imp.is_type_only) imports.append(allocator, compilation.interner.get(imp.module)) catch return null;
            } else if (compilation.hir.kindOf(statement) == .export_decl) {
                const ex = hir_mod.exportOf(&compilation.hir, statement);
                if (ex.is_export_equals) continue;
                is_esm.* = true;
                const target = compilation.interner.get(ex.module);
                if (!ex.is_type_only and target.len != 0) imports.append(allocator, target) catch return null;
            }
        }
    }
    static_imports.* = std.json.Stringify.valueAlloc(allocator, imports.items, .{}) catch return null;
    if (compilation.has_syntactic_parse_diagnostics) {
        for (compilation.diagnostics.items) |diagnostic| {
            if (diagnostic.is_syntactic) {
                std.debug.print("{s}:{d}: {s} (TS{d})\n", .{ path, diagnostic.pos, diagnostic.message, diagnostic.code });
                break;
            }
        }
    }
    // Choose from parsed identifiers, including escaped and nested bindings, so
    // host metadata remains lexical even when a function shadows `module`.
    var buffer: [80]u8 = undefined;
    var suffix: usize = 0;
    while (true) : (suffix += 1) {
        const name = std.fmt.bufPrint(&buffer, "__home_import_meta_{d}", .{suffix}) catch return null;
        if (compilation.interner.lookup(name) == null) {
            meta_binding.* = allocator.dupe(u8, name) catch return null;
            break;
        }
    }
    options.emit.import_meta_binding = meta_binding.*;
    suffix = 0;
    while (true) : (suffix += 1) {
        const name = std.fmt.bufPrint(&buffer, "__home_dynamic_import_{d}", .{suffix}) catch return null;
        if (compilation.interner.lookup(name) == null) {
            dynamic_binding.* = allocator.dupe(u8, name) catch return null;
            break;
        }
    }
    options.emit.commonjs_dynamic_import_binding = dynamic_binding.*;
    if (is_esm.*) {
        suffix = 0;
        while (true) : (suffix += 1) {
            const name = std.fmt.bufPrint(&buffer, "__home_module_{d}", .{suffix}) catch return null;
            if (compilation.interner.lookup(name) == null) {
                module_binding.* = allocator.dupe(u8, name) catch return null;
                break;
            }
        }
        options.emit.commonjs_module_binding = module_binding.*;
        suffix = 0;
        while (true) : (suffix += 1) {
            const name = std.fmt.bufPrint(&buffer, "__home_static_import_{d}", .{suffix}) catch return null;
            if (compilation.interner.lookup(name) == null) {
                import_binding.* = allocator.dupe(u8, name) catch return null;
                break;
            }
        }
        options.emit.commonjs_import_binding = import_binding.*;
    }
    return ts_driver.emitPreparedSource(compilation, options.emit) catch null;
}

fn resolveModuleNative(
    ctx: ?*JSContextRef,
    function: ?*JSObject,
    this_object: ?*JSObject,
    argument_count: usize,
    arguments: [*c]const ?*JSValue,
    exception: extern_fns.ExceptionRef,
) callconv(.c) ?*JSValue {
    _ = function;
    _ = this_object;
    _ = exception;
    const c = ctx orelse return null;
    if (argument_count < 2 or arguments[0] == null or arguments[1] == null)
        return extern_fns.JSValueMakeNull(c);
    const allocator = std.heap.smp_allocator;
    const specifier = valueToOwnedUtf8(c, arguments[0].?, allocator) orelse return extern_fns.JSValueMakeNull(c);
    defer allocator.free(specifier);
    const parent_path = valueToOwnedUtf8(c, arguments[1].?, allocator) orelse return extern_fns.JSValueMakeNull(c);
    defer allocator.free(parent_path);
    const alias = @import("tool_paths.zig").resolve(allocator, specifier, parent_path, tryPath) catch |err| {
        const object = extern_fns.JSObjectMake(c, null, null) orelse return extern_fns.JSValueMakeNull(c);
        setProperty(c, object, "error", stringValue(c, @errorName(err)));
        setProperty(c, object, "code", stringValue(c, "ERR_HOME_TSCONFIG"));
        return @ptrCast(object);
    };
    // The install closure retains this immutable JSON string per realm. No
    // process-global conditions or mutable public process flags affect resolution.
    const conditions_json = if (argument_count > 4 and arguments[4] != null)
        valueToOwnedUtf8(c, arguments[4].?, allocator) orelse return extern_fns.JSValueMakeNull(c)
    else
        allocator.dupe(u8, "[]") catch return extern_fns.JSValueMakeNull(c);
    defer allocator.free(conditions_json);
    const conditions = std.json.parseFromSlice([]const []const u8, allocator, conditions_json, .{}) catch
        return extern_fns.JSValueMakeNull(c);
    defer conditions.deinit();
    const mode: package_exports.Mode = if (argument_count > 3 and arguments[3] != null and extern_fns.JSValueToBoolean(c, arguments[3])) .import else .require;
    const path = alias orelse (resolveModule(allocator, specifier, parent_path, mode, conditions.value) catch |err| {
        const object = extern_fns.JSObjectMake(c, null, null) orelse return extern_fns.JSValueMakeNull(c);
        setProperty(c, object, "error", stringValue(c, @errorName(err)));
        const code = if (err == error.ExportedFileNotFound and mode == .import) "ERR_MODULE_NOT_FOUND" else package_exports.code(err);
        setProperty(c, object, "code", stringValue(c, code));
        return @ptrCast(object);
    }) orelse return extern_fns.JSValueMakeNull(c);
    defer allocator.free(path);
    // require.resolve must neither read nor parse/evaluate the target. It can
    // resolve a file containing invalid JavaScript or non-JavaScript assets.
    if (argument_count > 2 and arguments[2] != null and extern_fns.JSValueToBoolean(c, arguments[2])) {
        const object = extern_fns.JSObjectMake(c, null, null) orelse return extern_fns.JSValueMakeNull(c);
        setProperty(c, object, "path", stringValue(c, path));
        return @ptrCast(object);
    }
    // A native addon can resolve without being executable by this host. Refuse
    // before reading its bytes: treating .node as TS can execute source text or
    // turn a binary into misleading parser errors and incomplete module state.
    if (std.mem.eql(u8, std.fs.path.extension(path), ".node")) {
        const object = extern_fns.JSObjectMake(c, null, null) orelse return extern_fns.JSValueMakeNull(c);
        setProperty(c, object, "error", stringValue(c, "NativeAddonUnsupported: Home cannot execute .node native addons"));
        setProperty(c, object, "code", stringValue(c, "ERR_HOME_UNSUPPORTED_NATIVE_ADDON"));
        return @ptrCast(object);
    }
    const source = std.Io.Dir.cwd().readFileAlloc(g_io, path, allocator, std.Io.Limit.unlimited) catch
        return extern_fns.JSValueMakeNull(c);
    defer allocator.free(source);
    var meta_binding: ?[]u8 = null;
    var module_binding: ?[]u8 = null;
    var import_binding: ?[]u8 = null;
    var dynamic_binding: ?[]u8 = null;
    defer if (dynamic_binding) |name| allocator.free(name);
    defer if (import_binding) |name| allocator.free(name);
    var is_esm = false;
    var top_await = false;
    var static_imports: ?[]u8 = null;
    defer if (static_imports) |json| allocator.free(json);
    defer if (meta_binding) |name| allocator.free(name);
    defer if (module_binding) |name| allocator.free(name);
    const emitted = emitModule(allocator, source, path, &meta_binding, &module_binding, &import_binding, &dynamic_binding, &is_esm, &top_await, &static_imports) orelse return extern_fns.JSValueMakeNull(c);
    defer allocator.free(emitted);

    const object = extern_fns.JSObjectMake(c, null, null) orelse return extern_fns.JSValueMakeNull(c);
    setProperty(c, object, "path", stringValue(c, path));
    setProperty(c, object, "source", stringValue(c, emitted));
    if (meta_binding) |name| setProperty(c, object, "metaBinding", stringValue(c, name));
    if (module_binding) |name| setProperty(c, object, "moduleBinding", stringValue(c, name));
    if (import_binding) |name| setProperty(c, object, "importBinding", stringValue(c, name));
    if (dynamic_binding) |name| setProperty(c, object, "dynamicImportBinding", stringValue(c, name));
    setProperty(c, object, "esModule", extern_fns.JSValueMakeBoolean(c, is_esm));
    setProperty(c, object, "topLevelAwait", extern_fns.JSValueMakeBoolean(c, top_await));
    if (static_imports) |json| setProperty(c, object, "staticImports", stringValue(c, json));
    setProperty(c, object, "format", stringValue(c, if (std.mem.eql(u8, std.fs.path.extension(path), ".json")) "json" else "commonjs"));
    return @ptrCast(object);
}

// Parse/emit an in-memory TypeScript module without resolving imports, checking
// types or executing its body. This is deliberately separate from emitModule's
// CommonJS host linkage: callers need ordinary ESM output for generated code.
fn transformTypeScriptNative(
    ctx: ?*JSContextRef,
    _: ?*JSObject,
    _: ?*JSObject,
    count: usize,
    args: [*c]const ?*JSValue,
    _: extern_fns.ExceptionRef,
) callconv(.c) ?*JSValue {
    const c = ctx orelse return null;
    if (count != 1 or !extern_fns.JSValueIsString(c, args[0])) return extern_fns.JSValueMakeNull(c);
    const allocator = std.heap.smp_allocator;
    const source = valueToOwnedUtf8(c, args[0].?, allocator) orelse return extern_fns.JSValueMakeNull(c);
    defer allocator.free(source);
    const result = extern_fns.JSObjectMake(c, null, null) orelse return extern_fns.JSValueMakeNull(c);
    const options: ts_driver.CompileOptions = .{
        .continue_on_error = false,
        .bind_only = true,
        .no_resolve = true,
        .no_lib = true,
        .emit = .{ .module_kind = .esm, .es_target = .esnext },
    };
    const compilation = ts_driver.prepareSource(allocator, source, options) catch |err| {
        setProperty(c, result, "error", stringValue(c, @errorName(err)));
        return @ptrCast(result);
    };
    defer {
        compilation.deinit();
        allocator.destroy(compilation);
    }
    for (compilation.diagnostics.items) |diagnostic| {
        if (!diagnostic.isSyntactic()) continue;
        const message = std.fmt.allocPrint(allocator, "{s} (TS{d}, byte {d})", .{ diagnostic.message, diagnostic.code, diagnostic.pos }) catch return extern_fns.JSValueMakeNull(c);
        defer allocator.free(message);
        setProperty(c, result, "syntax", stringValue(c, message));
        return @ptrCast(result);
    }
    const emitted = ts_driver.emitPreparedSource(compilation, options.emit) catch |err| {
        setProperty(c, result, "error", stringValue(c, @errorName(err)));
        return @ptrCast(result);
    };
    defer allocator.free(emitted);
    setProperty(c, result, "source", stringValue(c, emitted));
    return @ptrCast(result);
}

// System JSC does not retain eval sourceURL directives in Error.stack.
// Its public evaluator supplies the same generated-source URL explicitly.
fn evaluateModuleNative(
    ctx: ?*JSContextRef,
    _: ?*JSObject,
    _: ?*JSObject,
    argument_count: usize,
    arguments: [*c]const ?*JSValue,
    exception: extern_fns.ExceptionRef,
) callconv(.c) ?*JSValue {
    const c = ctx orelse return null;
    if (argument_count != 2 or arguments[0] == null or arguments[1] == null) return null;
    const source = extern_fns.JSValueToStringCopy(c, arguments[0].?, exception) orelse return null;
    defer extern_fns.JSStringRelease(source);
    const url = extern_fns.JSValueToStringCopy(c, arguments[1].?, exception) orelse return null;
    defer extern_fns.JSStringRelease(url);
    return extern_fns.JSEvaluateScript(c, source, null, url, 1, exception);
}

const install_glue = @embedFile("tool_modules.js");

pub fn install(allocator: std.mem.Allocator, ctx: *JSContextRef, global: *JSGlobalObject) void {
    installWithConditions(allocator, ctx, global, &.{});
}

pub fn installWithConditions(allocator: std.mem.Allocator, ctx: *JSContextRef, global: *JSGlobalObject, conditions: []const []const u8) void {
    callback.registerCallback(ctx, global, "__home_tool_transform_ts", transformTypeScriptNative);
    const transpiler = evaluate.evaluateUtf8Detailed(allocator, ctx, @embedFile("tool_transpiler.js"), "home:tool-transpiler-install", 1) catch return;
    defer transpiler.deinit(allocator);
    if (transpiler.exception != null) return;
    const json = std.json.Stringify.valueAlloc(allocator, conditions, .{}) catch return;
    defer allocator.free(json);
    setProperty(ctx, @ptrCast(global), "__home_tool_conditions", stringValue(ctx, json));
    callback.registerCallback(ctx, global, "__home_tool_resolve_module", resolveModuleNative);
    if (comptime !@import("build_options").use_zig_js)
        callback.registerCallback(ctx, global, "__home_tool_evaluate_module", evaluateModuleNative);
    const result = evaluate.evaluateUtf8Detailed(allocator, ctx, install_glue, "home:tool-module-install", 1) catch return;
    result.deinit(allocator);
}
