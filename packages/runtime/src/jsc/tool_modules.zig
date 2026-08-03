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

const JSValue = opaques.JSValue;
const JSContextRef = opaques.JSContextRef;
const JSObject = opaques.JSObject;
const JSGlobalObject = opaques.JSGlobalObject;
const g_io = std.Io.Threaded.global_single_threaded.io();

const extensions = [_][]const u8{ ".ts", ".tsx", ".mts", ".cts", ".js", ".mjs", ".cjs", ".json" };

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
    const resolved = std.fs.path.resolve(allocator, &.{path}) catch return null;
    if (isFile(resolved)) return resolved;
    allocator.free(resolved);
    return null;
}

fn tryWithExtensions(allocator: std.mem.Allocator, base: []const u8) ?[]u8 {
    if (resolvedFile(allocator, base)) |path| return path;
    if (std.fs.path.extension(base).len != 0) return null;
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

fn resolveModule(allocator: std.mem.Allocator, specifier: []const u8, parent_path: []const u8) ?[]u8 {
    if (specifier.len == 0) return null;
    const parent_dir = if (parent_path.len == 0)
        "."
    else
        std.fs.path.dirname(parent_path) orelse ".";
    const path_like = std.fs.path.isAbsolute(specifier) or
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

    var search_dir = std.fs.path.resolve(allocator, &.{parent_dir}) catch return null;
    defer allocator.free(search_dir);
    while (true) {
        const candidate = std.fs.path.join(allocator, &.{ search_dir, "node_modules", specifier }) catch return null;
        defer allocator.free(candidate);
        if (tryPath(allocator, candidate)) |path| return path;
        const next = std.fs.path.dirname(search_dir) orelse {
            if (!std.mem.eql(u8, search_dir, ".")) {
                const replacement = allocator.dupe(u8, ".") catch return null;
                allocator.free(search_dir);
                search_dir = replacement;
                continue;
            }
            break;
        };
        if (std.mem.eql(u8, next, search_dir)) break;
        const replacement = allocator.dupe(u8, next) catch return null;
        allocator.free(search_dir);
        search_dir = replacement;
    }
    return null;
}

fn emitModule(allocator: std.mem.Allocator, source: []const u8, path: []const u8) ?[]u8 {
    if (std.mem.eql(u8, std.fs.path.extension(path), ".json"))
        return allocator.dupe(u8, source) catch null;
    const is_tsx = std.mem.endsWith(u8, path, ".tsx");
    var compilation = ts_driver.compileSource(allocator, source, .{
        .continue_on_error = false,
        .is_tsx = is_tsx,
        .jsx_option_present = is_tsx,
        .importer_path = path,
        .emit = .{ .module_kind = .commonjs },
    }) catch return null;
    defer {
        compilation.deinit();
        allocator.destroy(compilation);
    }
    return allocator.dupe(u8, compilation.js) catch null;
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
    const path = resolveModule(allocator, specifier, parent_path) orelse return extern_fns.JSValueMakeNull(c);
    defer allocator.free(path);
    const source = std.Io.Dir.cwd().readFileAlloc(g_io, path, allocator, std.Io.Limit.unlimited) catch
        return extern_fns.JSValueMakeNull(c);
    defer allocator.free(source);
    const emitted = emitModule(allocator, source, path) orelse return extern_fns.JSValueMakeNull(c);
    defer allocator.free(emitted);

    const object = extern_fns.JSObjectMake(c, null, null) orelse return extern_fns.JSValueMakeNull(c);
    setProperty(c, object, "path", stringValue(c, path));
    setProperty(c, object, "source", stringValue(c, emitted));
    setProperty(c, object, "format", stringValue(c, if (std.mem.eql(u8, std.fs.path.extension(path), ".json")) "json" else "commonjs"));
    return @ptrCast(object);
}

const install_glue =
    \\(function() {
    \\  var resolveNative = globalThis.__home_tool_resolve_module;
    \\  var cache = Object.create(null);
    \\  var mainModule = null;
    \\  function load(specifier, parentPath, asMain) {
    \\    var payload = resolveNative(String(specifier), String(parentPath || ""));
    \\    if (payload === null) throw new Error("cannot resolve module " + specifier + (parentPath ? " from " + parentPath : ""));
    \\    if (Object.prototype.hasOwnProperty.call(cache, payload.path)) return cache[payload.path].exports;
    \\    var module = { id: payload.path, filename: payload.path, loaded: false, exports: {}, parent: null, children: [] };
    \\    cache[payload.path] = module;
    \\    if (asMain) mainModule = module;
    \\    if (payload.format === "json") {
    \\      module.exports = JSON.parse(payload.source);
    \\      module.loaded = true;
    \\      return module.exports;
    \\    }
    \\    var slash = payload.path.lastIndexOf("/");
    \\    var directory = slash < 0 ? "." : payload.path.slice(0, slash);
    \\    function localRequire(request) { return load(request, payload.path, false); }
    \\    localRequire.resolve = function(request) {
    \\      var resolved = resolveNative(String(request), payload.path);
    \\      if (resolved === null) throw new Error("cannot resolve module " + request + " from " + payload.path);
    \\      return resolved.path;
    \\    };
    \\    localRequire.cache = cache;
    \\    Object.defineProperty(localRequire, "main", { get: function() { return mainModule; } });
    \\    module.require = localRequire;
    \\    var wrapper = (0, eval)("(function(exports, require, module, __filename, __dirname) {\n" + payload.source + "\n})");
    \\    wrapper(module.exports, localRequire, module, payload.path, directory);
    \\    module.loaded = true;
    \\    return module.exports;
    \\  }
    \\  Home.resolveModule = function(specifier, parentPath) {
    \\    var resolved = resolveNative(String(specifier), String(parentPath || ""));
    \\    if (resolved === null) throw new Error("cannot resolve module " + specifier);
    \\    return resolved.path;
    \\  };
    \\  Home.require = function(specifier) { return load(specifier, "", false); };
    \\  Home.runModule = function(specifier) { return load(specifier, "", true); };
    \\  globalThis.require = Home.require;
    \\  delete globalThis.__home_tool_resolve_module;
    \\})();
;

pub fn install(allocator: std.mem.Allocator, ctx: *JSContextRef, global: *JSGlobalObject) void {
    callback.registerCallback(ctx, global, "__home_tool_resolve_module", resolveModuleNative);
    const result = evaluate.evaluateUtf8Detailed(allocator, ctx, install_glue, "home:tool-module-install", 1) catch return;
    result.deinit(allocator);
}
