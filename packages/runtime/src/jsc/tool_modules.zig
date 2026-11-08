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
    if (!isFile(path)) return null;
    const canonical = std.Io.Dir.cwd().realPathFileAlloc(g_io, path, allocator) catch return null;
    defer allocator.free(canonical);
    return allocator.dupe(u8, canonical) catch null;
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

fn resolveModule(allocator: std.mem.Allocator, specifier: []const u8, parent_path: []const u8) ?[]u8 {
    if (specifier.len == 0) return null;
    const parent_dir = if (parent_path.len == 0)
        "."
    else
        std.fs.path.dirname(parent_path) orelse ".";
    if (specifier[0] == '#') return resolvePackageImport(allocator, specifier, parent_dir);
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

fn emitModule(allocator: std.mem.Allocator, source: []const u8, path: []const u8, meta_binding: *?[]u8, module_binding: *?[]u8, is_esm: *bool) ?[]u8 {
    meta_binding.* = null;
    module_binding.* = null;
    is_esm.* = false;
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
    if (compilation.root != hir_mod.none_node_id) {
        for (hir_mod.blockStmts(&compilation.hir, compilation.root)) |statement| {
            if ((compilation.hir.kindOf(statement) == .import_decl and !hir_mod.importOf(&compilation.hir, statement).is_require_equals) or
                (compilation.hir.kindOf(statement) == .export_decl and !hir_mod.exportOf(&compilation.hir, statement).is_export_equals))
            {
                is_esm.* = true;
                break;
            }
        }
    }
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
    const path = resolveModule(allocator, specifier, parent_path) orelse return extern_fns.JSValueMakeNull(c);
    defer allocator.free(path);
    // require.resolve must neither read nor parse/evaluate the target. It can
    // resolve a file containing invalid JavaScript or non-JavaScript assets.
    if (argument_count > 2 and arguments[2] != null and extern_fns.JSValueToBoolean(c, arguments[2])) {
        const object = extern_fns.JSObjectMake(c, null, null) orelse return extern_fns.JSValueMakeNull(c);
        setProperty(c, object, "path", stringValue(c, path));
        return @ptrCast(object);
    }
    const source = std.Io.Dir.cwd().readFileAlloc(g_io, path, allocator, std.Io.Limit.unlimited) catch
        return extern_fns.JSValueMakeNull(c);
    defer allocator.free(source);
    var meta_binding: ?[]u8 = null;
    var module_binding: ?[]u8 = null;
    var is_esm = false;
    defer if (meta_binding) |name| allocator.free(name);
    defer if (module_binding) |name| allocator.free(name);
    const emitted = emitModule(allocator, source, path, &meta_binding, &module_binding, &is_esm) orelse return extern_fns.JSValueMakeNull(c);
    defer allocator.free(emitted);

    const object = extern_fns.JSObjectMake(c, null, null) orelse return extern_fns.JSValueMakeNull(c);
    setProperty(c, object, "path", stringValue(c, path));
    setProperty(c, object, "source", stringValue(c, emitted));
    if (meta_binding) |name| setProperty(c, object, "metaBinding", stringValue(c, name));
    if (module_binding) |name| setProperty(c, object, "moduleBinding", stringValue(c, name));
    setProperty(c, object, "esModule", extern_fns.JSValueMakeBoolean(c, is_esm));
    setProperty(c, object, "format", stringValue(c, if (std.mem.eql(u8, std.fs.path.extension(path), ".json")) "json" else "commonjs"));
    return @ptrCast(object);
}

const install_glue =
    \\(function() {
    \\  var resolveNative = globalThis.__home_tool_resolve_module;
    \\  var builtins = globalThis.__home_tool_builtins || Object.create(null);
    \\  delete globalThis.__home_tool_builtins;
    \\  function isBuiltin(request) { return Object.prototype.hasOwnProperty.call(builtins, request); }
    \\  var cache = Object.create(null);
    \\  var mainModule = null;
    // The CommonJS emitter's default contract uses ambient interop helpers.
    // Keep ESM exports intact and wrap real CommonJS values, including primitives.
    \\  globalThis.__importDefault = function(value) {
    \\    return value && value.__esModule ? value : { default: value };
    \\  };
    \\  globalThis.__importStar = function(value) {
    \\    if (value && value.__esModule) return value;
    \\    var namespace = {};
    \\    if (value !== null && value !== undefined) Object.keys(Object(value)).forEach(function(key) {
    \\      if (key === "default") return;
    \\      var descriptor = Object.getOwnPropertyDescriptor(Object(value), key);
    \\      if (!descriptor || "get" in descriptor || descriptor.writable || descriptor.configurable) {
    \\        descriptor = { enumerable: true, get: function() { return value[key]; } };
    \\      }
    \\      Object.defineProperty(namespace, key, descriptor);
    \\    });
    \\    Object.defineProperty(namespace, "default", { enumerable: true, value: value });
    \\    return namespace;
    \\  };
    \\  function fileURL(path) { return "file://" + path.split("/").map(encodeURIComponent).join("/"); }
    \\  function makeRequire(parentPath) {
    \\    function localRequire(request) {
    \\      if (typeof request !== "string") throw new TypeError("Module id must be a string");
    \\      return load(request, parentPath, false);
    \\    }
    \\    localRequire.resolve = function(request) {
    \\      if (typeof request !== "string") throw new TypeError("Module id must be a string");
    \\      if (isBuiltin(request)) return request;
    \\      var resolved = resolveNative(request, parentPath, true);
    \\      if (resolved === null) throw new Error("cannot resolve module " + request + " from " + parentPath);
    \\      return resolved.path;
    \\    };
    \\    localRequire.cache = cache;
    \\    Object.defineProperty(localRequire, "main", { get: function() { return mainModule; } });
    \\    return localRequire;
    \\  }
    \\  function load(specifier, parentPath, asMain) {
    \\    specifier = String(specifier);
    \\    if (isBuiltin(specifier)) return builtins[specifier];
    \\    var payload = resolveNative(String(specifier), String(parentPath || ""));
    \\    if (payload === null) throw new Error("cannot resolve module " + specifier + (parentPath ? " from " + parentPath : ""));
    \\    if (Object.prototype.hasOwnProperty.call(cache, payload.path)) return cache[payload.path].exports;
    \\    var module = { id: payload.path, filename: payload.path, loaded: false, exports: {}, parent: null, children: [] };
    \\    if (payload.esModule) Object.defineProperty(module.exports, "__esModule", { value: true });
    \\    cache[payload.path] = module;
    \\    if (asMain) mainModule = module;
    \\    if (payload.format === "json") {
    \\      module.exports = JSON.parse(payload.source);
    \\      module.loaded = true;
    \\      return module.exports;
    \\    }
    \\    var slash = payload.path.lastIndexOf("/");
    \\    var directory = slash < 0 ? "." : payload.path.slice(0, slash);
    \\    var localRequire = makeRequire(payload.path);
    \\    module.require = localRequire;
    // ECMA-262 import.meta Evaluation creates one extensible, null-prototype
    // object per module. The host supplies real file metadata and main identity.
    \\    var metadata = Object.create(null);
    \\    metadata.url = fileURL(payload.path);
    \\    metadata.path = payload.path;
    \\    metadata.dir = directory;
    \\    metadata.file = payload.path.slice(slash + 1);
    \\    metadata.dirname = directory;
    \\    metadata.filename = payload.path;
    \\    metadata.env = process.env;
    \\    metadata.main = !!asMain;
    \\    metadata.require = localRequire;
    // Capture metadata outside the CommonJS wrapper so its five arguments keep
    // the same observable shape as modules without import.meta.
    \\    var wrapper = (0, eval)("(function(" + payload.metaBinding + ", module) { return function(exports, require, " + (payload.moduleBinding || "module") + ", __filename, __dirname) {\n" + payload.source + "\n}; })")(metadata, module);
    \\    wrapper(module.exports, localRequire, module, payload.path, directory);
    \\    module.loaded = true;
    \\    return module.exports;
    \\  }
    \\  Home.resolveModule = function(specifier, parentPath) {
    \\    specifier = String(specifier);
    \\    if (isBuiltin(specifier)) return specifier;
    \\    var resolved = resolveNative(String(specifier), String(parentPath || ""), true);
    \\    if (resolved === null) throw new Error("cannot resolve module " + specifier);
    \\    return resolved.path;
    \\  };
    \\  Home.createRequire = function(parentPath) {
    \\    if (typeof parentPath !== "string" || parentPath.charAt(0) !== "/" || parentPath.indexOf("\0") !== -1) throw new TypeError("Home require referrer must be an absolute POSIX filename");
    \\    if (parentPath.charAt(parentPath.length - 1) === "/") parentPath += "__home_require__.js";
    \\    return makeRequire(parentPath);
    \\  };
    \\  Home.require = makeRequire("");
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
