// Phase 3 — a minimal native `Bun` global for the eval/run realm, starting
// with the file I/O surface most scripts use: `Bun.file(path)` and
// `Bun.write(path, data)`, backed by Home's real native file read/write/stat
// (via the shared single-threaded `std.Io`) — not a shim.
//
//   - `Bun.file(path)` -> a `BunFile` with async `text`/`json`/`arrayBuffer`/
//     `bytes`/`exists` and a sync `size`/`name`/`type`.
//   - `Bun.write(path, data)` -> bytes written (data: string | Uint8Array |
//     ArrayBuffer | Blob | Response-ish with `_bytes`).
//   - `Bun.version` — the pinned Bun-compat version.
//
// NOTE: this is the first time the realm exposes a `Bun` global; it is Home's
// OWN native implementation, NOT delegation to a system `bun` binary. Builds
// on the web globals (TextEncoder/Decoder); installed after them.
// comptime-gated on `enable_jsc`.

const std = @import("std");
const build_options = @import("build_options");
const evaluate = @import("evaluate.zig");
const callback = @import("callback.zig");
const extern_fns = @import("extern_fns.zig");
const opaques = @import("opaques.zig");

const JSValue = opaques.JSValue;
const JSContextRef = opaques.JSContextRef;
const JSObject = opaques.JSObject;
const JSGlobalObject = opaques.JSGlobalObject;

const bun_version = "1.3.14";

fn argToOwnedUtf8(ctx: *JSContextRef, value: *JSValue, allocator: std.mem.Allocator) ?[]u8 {
    const string = extern_fns.JSValueToStringCopy(ctx, value, null) orelse return null;
    defer extern_fns.JSStringRelease(string);
    const capacity = extern_fns.JSStringGetLength(string) * 4 + 1;
    const buf = allocator.alloc(u8, capacity) catch return null;
    const written = extern_fns.JSStringGetUTF8CString(string, buf.ptr, buf.len);
    return buf[0 .. if (written > 0) written - 1 else 0];
}

fn makeUint8Array(ctx: *JSContextRef, bytes: []const u8) ?*JSValue {
    const array = extern_fns.JSObjectMakeTypedArray(ctx, .kJSTypedArrayTypeUint8Array, bytes.len, null) orelse
        return extern_fns.JSValueMakeNull(ctx);
    if (bytes.len > 0) {
        if (extern_fns.JSObjectGetTypedArrayBytesPtr(ctx, array, null)) |ptr| {
            const dest: [*]u8 = @ptrCast(ptr);
            @memcpy(dest[0..bytes.len], bytes);
        }
    }
    return @ptrCast(array);
}

fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

/// `__home_bun_read_file(path)` -> Uint8Array or null.
fn readFileNative(ctx: ?*JSContextRef, function: ?*JSObject, this_object: ?*JSObject, argc: usize, argv: [*c]const ?*JSValue, exception: extern_fns.ExceptionRef) callconv(.c) ?*JSValue {
    _ = function;
    _ = this_object;
    _ = exception;
    const c = ctx orelse return null;
    if (argc < 1) return extern_fns.JSValueMakeNull(c);
    const v = argv[0] orelse return extern_fns.JSValueMakeNull(c);
    const allocator = std.heap.page_allocator;
    const path = argToOwnedUtf8(c, v, allocator) orelse return extern_fns.JSValueMakeNull(c);
    defer allocator.free(path);
    if (path.len == 0) return extern_fns.JSValueMakeNull(c);
    const bytes = std.Io.Dir.cwd().readFileAlloc(io(), path, allocator, std.Io.Limit.limited(256 * 1024 * 1024)) catch
        return extern_fns.JSValueMakeNull(c);
    defer allocator.free(bytes);
    return makeUint8Array(c, bytes);
}

/// `__home_bun_stat(path)` -> { exists: bool, size: number }.
fn statNative(ctx: ?*JSContextRef, function: ?*JSObject, this_object: ?*JSObject, argc: usize, argv: [*c]const ?*JSValue, exception: extern_fns.ExceptionRef) callconv(.c) ?*JSValue {
    _ = function;
    _ = this_object;
    _ = exception;
    const c = ctx orelse return null;
    const object = extern_fns.JSObjectMake(c, null, null) orelse return extern_fns.JSValueMakeNull(c);
    var exists = false;
    var size: f64 = 0;
    if (argc >= 1) {
        if (argv[0]) |v| {
            const allocator = std.heap.page_allocator;
            if (argToOwnedUtf8(c, v, allocator)) |path| {
                defer allocator.free(path);
                if (std.Io.Dir.cwd().statFile(io(), path, .{})) |st| {
                    exists = true;
                    size = @floatFromInt(st.size);
                } else |_| {}
            }
        }
    }
    setBool(c, object, "exists", exists);
    setNum(c, object, "size", size);
    return @ptrCast(object);
}

/// `__home_bun_write_file(path, uint8array)` -> bytes written, or -1 on error.
fn writeFileNative(ctx: ?*JSContextRef, function: ?*JSObject, this_object: ?*JSObject, argc: usize, argv: [*c]const ?*JSValue, exception: extern_fns.ExceptionRef) callconv(.c) ?*JSValue {
    _ = function;
    _ = this_object;
    _ = exception;
    const c = ctx orelse return null;
    if (argc < 2) return extern_fns.JSValueMakeNumber(c, -1);
    const path_v = argv[0] orelse return extern_fns.JSValueMakeNumber(c, -1);
    const data_v = argv[1] orelse return extern_fns.JSValueMakeNumber(c, -1);
    const allocator = std.heap.page_allocator;
    const path = argToOwnedUtf8(c, path_v, allocator) orelse return extern_fns.JSValueMakeNumber(c, -1);
    defer allocator.free(path);

    // data must be a Uint8Array (the JS wrapper encodes strings/Blobs first).
    if (extern_fns.JSValueGetTypedArrayType(c, data_v, null) == .kJSTypedArrayTypeNone)
        return extern_fns.JSValueMakeNumber(c, -1);
    const obj = extern_fns.JSValueToObject(c, data_v, null) orelse return extern_fns.JSValueMakeNumber(c, -1);
    const len = extern_fns.JSObjectGetTypedArrayByteLength(c, obj, null);
    const ptr = extern_fns.JSObjectGetTypedArrayBytesPtr(c, obj, null);
    const bytes: []const u8 = if (len > 0 and ptr != null) @as([*]const u8, @ptrCast(ptr.?))[0..len] else "";
    std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = path, .data = bytes }) catch
        return extern_fns.JSValueMakeNumber(c, -1);
    return extern_fns.JSValueMakeNumber(c, @floatFromInt(len));
}

fn makeJsString(ctx: *JSContextRef, s: []const u8) ?*JSValue {
    const allocator = std.heap.page_allocator;
    const z = allocator.dupeZ(u8, s) catch return extern_fns.JSValueMakeNull(ctx);
    defer allocator.free(z);
    const js = extern_fns.JSStringCreateWithUTF8CString(z.ptr) orelse return extern_fns.JSValueMakeNull(ctx);
    defer extern_fns.JSStringRelease(js);
    return extern_fns.JSValueMakeString(ctx, js);
}

/// `__home_bun_hash(algo, bytesUint8Array, seed)` -> decimal string of the hash.
/// algo: 0 wyhash / 1 crc32 / 2 adler32 / 3 cityHash32 / 4 cityHash64 /
/// 5 murmur32v3 / 6 murmur64v2. The JS wrapper turns it into a Number/BigInt.
fn bunHashNative(ctx: ?*JSContextRef, function: ?*JSObject, this_object: ?*JSObject, argc: usize, argv: [*c]const ?*JSValue, exception: extern_fns.ExceptionRef) callconv(.c) ?*JSValue {
    _ = function;
    _ = this_object;
    _ = exception;
    const c = ctx orelse return null;
    if (argc < 2) return makeJsString(c, "0");
    const algo: u8 = @intFromFloat(extern_fns.JSValueToNumber(c, argv[0].?, null));
    const data_v = argv[1] orelse return makeJsString(c, "0");
    if (extern_fns.JSValueGetTypedArrayType(c, data_v, null) == .kJSTypedArrayTypeNone) return makeJsString(c, "0");
    const obj = extern_fns.JSValueToObject(c, data_v, null) orelse return makeJsString(c, "0");
    const len = extern_fns.JSObjectGetTypedArrayByteLength(c, obj, null);
    const ptr = extern_fns.JSObjectGetTypedArrayBytesPtr(c, obj, null);
    const input: []const u8 = if (len > 0 and ptr != null) @as([*]const u8, @ptrCast(ptr.?))[0..len] else "";
    var seed: u64 = 0;
    if (argc >= 3) {
        if (argv[2]) |sv| {
            if (!extern_fns.JSValueIsUndefined(c, sv) and !extern_fns.JSValueIsNull(c, sv)) {
                const sf = extern_fns.JSValueToNumber(c, sv, null);
                if (sf >= 0) seed = @intFromFloat(sf);
            }
        }
    }
    const v: u64 = switch (algo) {
        0 => std.hash.Wyhash.hash(seed, input),
        1 => std.hash.Crc32.hash(input),
        2 => std.hash.Adler32.hash(input),
        3 => std.hash.cityhash.CityHash32.hash(input),
        4 => std.hash.cityhash.CityHash64.hashWithSeed(input, seed),
        5 => std.hash.murmur.Murmur3_32.hashWithSeed(input, @truncate(seed)),
        6 => std.hash.murmur.Murmur2_64.hashWithSeed(input, seed),
        else => 0,
    };
    var buf: [24]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{v}) catch return makeJsString(c, "0");
    return makeJsString(c, s);
}

fn setBool(ctx: *JSContextRef, object: *JSObject, key: []const u8, value: bool) void {
    setValue(ctx, object, key, extern_fns.JSValueMakeBoolean(ctx, value));
}
fn setNum(ctx: *JSContextRef, object: *JSObject, key: []const u8, value: f64) void {
    setValue(ctx, object, key, extern_fns.JSValueMakeNumber(ctx, value));
}
fn setValue(ctx: *JSContextRef, object: *JSObject, key: []const u8, value: ?*JSValue) void {
    const allocator = std.heap.page_allocator;
    const key_z = allocator.dupeZ(u8, key) catch return;
    defer allocator.free(key_z);
    const name = extern_fns.JSStringCreateWithUTF8CString(key_z.ptr) orelse return;
    defer extern_fns.JSStringRelease(name);
    extern_fns.JSObjectSetProperty(ctx, object, name, value, 0, null);
}

const install_glue =
    \\(function() {
    \\  var readFn = globalThis.__home_bun_read_file;
    \\  var statFn = globalThis.__home_bun_stat;
    \\  var writeFn = globalThis.__home_bun_write_file;
    \\  var hashFn = globalThis.__home_bun_hash;
    \\
    \\  function toBytes(data) {
    \\    if (typeof data === "string") return new TextEncoder().encode(data);
    \\    if (data && data._bytes instanceof Uint8Array) return data._bytes;
    \\    if (data instanceof ArrayBuffer) return new Uint8Array(data.slice(0));
    \\    if (ArrayBuffer.isView(data)) return new Uint8Array(data.buffer.slice(data.byteOffset, data.byteOffset + data.byteLength));
    \\    return new TextEncoder().encode(String(data));
    \\  }
    \\
    \\  class BunFile {
    \\    constructor(path, options) { this._path = String(path); this.type = options && options.type ? String(options.type) : ""; }
    \\    get name() { return this._path; }
    \\    get size() { var s = statFn(this._path); return s.exists ? s.size : 0; }
    \\    exists() { return Promise.resolve(statFn(this._path).exists); }
    \\    bytes() { var b = readFn(this._path); var p = this._path; return b === null ? Promise.reject(new Error("ENOENT: no such file: " + p)) : Promise.resolve(b.slice()); }
    \\    arrayBuffer() { var b = readFn(this._path); var p = this._path; return b === null ? Promise.reject(new Error("ENOENT: no such file: " + p)) : Promise.resolve(b.buffer.slice(b.byteOffset, b.byteOffset + b.byteLength)); }
    \\    text() { var b = readFn(this._path); var p = this._path; return b === null ? Promise.reject(new Error("ENOENT: no such file: " + p)) : Promise.resolve(new TextDecoder().decode(b)); }
    \\    json() { return this.text().then(JSON.parse); }
    \\  }
    \\
    \\  function bunDeepEquals(a, b, strict) {
    \\    if (a === b) return true;
    \\    if (a === null || b === null || typeof a !== "object" || typeof b !== "object") {
    \\      return (!strict && a == b) || (a !== a && b !== b);
    \\    }
    \\    if (Array.isArray(a) !== Array.isArray(b)) return false;
    \\    if (ArrayBuffer.isView(a) || ArrayBuffer.isView(b)) {
    \\      if (a.length !== b.length) return false;
    \\      for (var i = 0; i < a.length; i++) if (a[i] !== b[i]) return false;
    \\      return true;
    \\    }
    \\    var ka = Object.keys(a), kb = Object.keys(b);
    \\    if (ka.length !== kb.length) return false;
    \\    for (var j = 0; j < ka.length; j++) {
    \\      if (!Object.prototype.hasOwnProperty.call(b, ka[j])) return false;
    \\      if (!bunDeepEquals(a[ka[j]], b[ka[j]], strict)) return false;
    \\    }
    \\    return true;
    \\  }
    \\  var htmlEsc = { "&": "&amp;", "<": "&lt;", ">": "&gt;", "\"": "&quot;", "'": "&#x27;" };
    \\  globalThis.Bun = {
    \\    version: __HOME_BUN_VERSION__,
    \\    file: function(path, options) { return new BunFile(path, options); },
    \\    write: function(path, data) {
    \\      var dest = (path && path._path) ? path._path : String(path);
    \\      var n = writeFn(dest, toBytes(data));
    \\      if (n < 0) return Promise.reject(new Error("Bun.write failed: " + dest));
    \\      return Promise.resolve(n);
    \\    },
    \\    get env() { return (typeof globalThis.process !== "undefined" && globalThis.process.env) || {}; },
    \\    sleep: function(ms) { return new Promise(function(res) { setTimeout(res, ms instanceof Date ? Math.max(0, ms.getTime() - Date.now()) : ms); }); },
    \\    nanoseconds: function() { return Math.trunc((typeof performance !== "undefined" ? performance.now() : 0) * 1e6); },
    \\    inspect: function(v, opts) { var u = (typeof globalThis.require === "function") ? globalThis.require("node:util") : null; return u ? u.inspect(v, opts) : String(v); },
    \\    deepEquals: function(a, b, strict) { return bunDeepEquals(a, b, !!strict); },
    \\    escapeHTML: function(s) { return String(s).replace(/[&<>"']/g, function(c) { return htmlEsc[c]; }); },
    \\    stringWidth: function(s) { return String(s).replace(/\x1b\[[0-9;]*m/g, "").length; },
    \\  };
    \\  delete globalThis.__home_bun_read_file;
    \\  delete globalThis.__home_bun_stat;
    \\  (function() {
    \\    function hbytes(d) { return typeof d === "string" ? new TextEncoder().encode(d) : (d instanceof Uint8Array ? d : new Uint8Array(ArrayBuffer.isView(d) ? d.buffer : d)); }
    \\    function h64(algo, d, seed) { return BigInt(hashFn(algo, hbytes(d), seed === undefined ? 0 : Number(seed))); }
    \\    function h32(algo, d, seed) { return Number(hashFn(algo, hbytes(d), seed === undefined ? 0 : Number(seed))); }
    \\    var bunHash = function(d, seed) { return h64(0, d, seed); };
    \\    bunHash.wyhash = function(d, seed) { return h64(0, d, seed); };
    \\    bunHash.crc32 = function(d) { return h32(1, d); };
    \\    bunHash.adler32 = function(d) { return h32(2, d); };
    \\    bunHash.cityHash32 = function(d) { return h32(3, d); };
    \\    bunHash.cityHash64 = function(d, seed) { return h64(4, d, seed); };
    \\    bunHash.murmur32v3 = function(d, seed) { return h32(5, d, seed); };
    \\    bunHash.murmur64v2 = function(d, seed) { return h64(6, d, seed); };
    \\    globalThis.Bun.hash = bunHash;
    \\  })();
    \\  (function() {
    \\    function globToRegExp(pattern) {
    \\      var re = "", i = 0, n = pattern.length, depth = 0;
    \\      while (i < n) {
    \\        var c = pattern[i++];
    \\        if (c === "*") {
    \\          if (pattern[i] === "*") { i++; if (pattern[i] === "/") i++; re += ".*"; } else re += "[^/]*";
    \\        } else if (c === "?") re += "[^/]";
    \\        else if (c === "[") {
    \\          var cls = "["; if (pattern[i] === "!" || pattern[i] === "^") { cls += "^"; i++; }
    \\          while (i < n && pattern[i] !== "]") { var cc = pattern[i++]; cls += (cc === "\\") ? "\\\\" : cc; }
    \\          if (i < n) i++; re += cls + "]";
    \\        } else if (c === "{") { re += "(?:"; depth++; }
    \\        else if (c === "}" && depth > 0) { re += ")"; depth--; }
    \\        else if (c === "," && depth > 0) re += "|";
    \\        else if (".+()|^$\\".indexOf(c) >= 0) re += "\\" + c;
    \\        else re += c;
    \\      }
    \\      return new RegExp("^" + re + "$");
    \\    }
    \\    function Glob(pattern) { this.pattern = String(pattern); this._re = globToRegExp(this.pattern); }
    \\    Glob.prototype.match = function(str) { return this._re.test(String(str)); };
    \\    Glob.prototype.scan = function() { throw Object.assign(new Error("Bun.Glob.scan is not implemented yet (needs directory iteration)"), { code: "ENOSYS" }); };
    \\    globalThis.Bun.Glob = Glob;
    \\  })();
    \\  delete globalThis.__home_bun_hash;
    \\  delete globalThis.__home_bun_write_file;
    \\})();
;

/// Install the minimal native `Bun` global. No-op without JSC. Must run after
/// the web globals (relies on `TextEncoder`/`TextDecoder`).
pub fn install(allocator: std.mem.Allocator, ctx: *JSContextRef, global: *JSGlobalObject) void {
    if (comptime !build_options.enable_jsc) return;

    callback.registerCallback(ctx, global, "__home_bun_read_file", readFileNative);
    callback.registerCallback(ctx, global, "__home_bun_stat", statNative);
    callback.registerCallback(ctx, global, "__home_bun_write_file", writeFileNative);
    callback.registerCallback(ctx, global, "__home_bun_hash", bunHashNative);

    // Inject the version literal into the glue (kept out of the raw string).
    const glue = std.mem.replaceOwned(u8, allocator, install_glue, "__HOME_BUN_VERSION__", "\"" ++ bun_version ++ "\"") catch return;
    defer allocator.free(glue);
    const result = evaluate.evaluateUtf8Detailed(allocator, ctx, glue, "home:bun-install", 1) catch return;
    result.deinit(allocator);
}

fn evalBool(allocator: std.mem.Allocator, ctx: *JSContextRef, source: []const u8) !bool {
    const value = (try evaluate.evaluateUtf8(allocator, ctx, source, "home:bun-probe", 1, null)) orelse
        return error.JSEvaluateReturnedNull;
    return extern_fns.JSValueToBoolean(ctx, value);
}

fn installRealm(allocator: std.mem.Allocator, ctx: *JSContextRef, global: *JSGlobalObject) void {
    @import("web_globals.zig").install(allocator, ctx, global);
    install(allocator, ctx, global);
}

// Full realm for the utility batch (env/sleep/nanoseconds/inspect need
// process/timers/misc/node_modules), mirroring installRealmGlobals order.
fn installRealmFull(allocator: std.mem.Allocator, ctx: *JSContextRef, global: *JSGlobalObject) void {
    @import("web_globals.zig").install(allocator, ctx, global);
    @import("process.zig").install(allocator, ctx, global, &[_][]const u8{"home"});
    @import("timers_global.zig").install(allocator, ctx, global);
    @import("misc_globals.zig").install(allocator, ctx, global);
    install(allocator, ctx, global);
    @import("node_modules.zig").install(allocator, ctx, global);
}

test "Bun utility batch: deepEquals/escapeHTML/stringWidth" {
    if (!build_options.enable_jsc) return error.SkipZigTest;
    const Engine = @import("engine.zig").Engine;
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();
    const ctx = engine.currentContext();
    installRealm(std.testing.allocator, ctx, engine.currentGlobalObject());

    try std.testing.expect(try evalBool(std.testing.allocator, ctx,
        "(function() {" ++
        "  if (!Bun.deepEquals({ a: 1, b: [2, 3] }, { a: 1, b: [2, 3] })) return false;" ++
        "  if (Bun.deepEquals({ a: 1 }, { a: 2 })) return false;" ++
        "  if (Bun.escapeHTML('<a href=\"x\">&') !== '&lt;a href=&quot;x&quot;&gt;&amp;') return false;" ++
        "  return Bun.stringWidth('ab\\u001b[31mcd\\u001b[0m') === 4; })()"));
}

test "Bun.hash family (native std.hash): crc32 vector + types/determinism" {
    if (!build_options.enable_jsc) return error.SkipZigTest;
    const Engine = @import("engine.zig").Engine;
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();
    const ctx = engine.currentContext();
    installRealm(std.testing.allocator, ctx, engine.currentGlobalObject());

    try std.testing.expect(try evalBool(std.testing.allocator, ctx,
        "(function() { var h = Bun.hash;" ++
        "  if (typeof h('abc') !== 'bigint' || h('abc') !== h('abc') || h('abc') === h('abd')) return false;" ++
        "  if (h.crc32('hello') !== 907060870) return false;" ++ // known CRC-32 (IsoHdlc) of 'hello'
        "  if (typeof h.crc32('x') !== 'number' || typeof h.adler32('x') !== 'number') return false;" ++
        "  if (typeof h.cityHash64('x') !== 'bigint' || typeof h.murmur32v3('x') !== 'number') return false;" ++
        "  if (h.wyhash('a', 0) !== h.wyhash('a', 0)) return false;" ++
        "  return h.wyhash('a', 1) !== h.wyhash('a', 2); })()"));
}

test "Bun.Glob.match (wildcards, globstar, braces, char classes)" {
    if (!build_options.enable_jsc) return error.SkipZigTest;
    const Engine = @import("engine.zig").Engine;
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();
    const ctx = engine.currentContext();
    installRealm(std.testing.allocator, ctx, engine.currentGlobalObject());

    try std.testing.expect(try evalBool(std.testing.allocator, ctx,
        "(function() { var G = Bun.Glob;" ++
        "  if (!new G('*.ts').match('foo.ts') || new G('*.ts').match('foo.js')) return false;" ++
        "  if (!new G('src/**/*.ts').match('src/a/b/c.ts')) return false;" ++
        "  if (!new G('**/*.ts').match('a/b.ts')) return false;" ++
        "  if (!new G('file-{a,b}.txt').match('file-b.txt') || new G('file-{a,b}.txt').match('file-c.txt')) return false;" ++
        "  if (!new G('?at').match('cat')) return false;" ++
        "  return new G('[hc]at').match('hat') && !new G('[hc]at').match('bat'); })()"));
}

test "Bun utility batch: env/sleep/nanoseconds/inspect (full realm)" {
    if (!build_options.enable_jsc) return error.SkipZigTest;
    const Engine = @import("engine.zig").Engine;
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();
    const ctx = engine.currentContext();
    installRealmFull(std.testing.allocator, ctx, engine.currentGlobalObject());

    _ = try evaluate.evaluateUtf8(std.testing.allocator, ctx,
        "globalThis.__bu = '';" ++
        "var ok = (Bun.env === process.env) && (typeof Bun.nanoseconds() === 'number') &&" ++
        "  (Bun.inspect({ a: 1 }).indexOf('a') >= 0);" ++
        "Bun.sleep(1).then(function() { globalThis.__bu = ok ? 'slept' : 'no'; });",
        "home:bun-util-setup", 1, null);
    @import("timers_global.zig").drain(ctx);
    try std.testing.expect(try evalBool(std.testing.allocator, ctx, "globalThis.__bu === 'slept'"));
}

test "Bun global exposes version + file/write surface" {
    if (!build_options.enable_jsc) return error.SkipZigTest;
    const Engine = @import("engine.zig").Engine;
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();
    const ctx = engine.currentContext();
    installRealm(std.testing.allocator, ctx, engine.currentGlobalObject());

    try std.testing.expect(try evalBool(std.testing.allocator, ctx,
        "typeof Bun === 'object' && Bun.version === '1.3.14' && " ++
        "typeof Bun.file === 'function' && typeof Bun.write === 'function' && " ++
        "typeof globalThis.__home_bun_read_file === 'undefined'"));
}

test "Bun.write then Bun.file round-trips through native fs" {
    if (!build_options.enable_jsc) return error.SkipZigTest;
    const path = "/tmp/home_bun_unit_test.txt";
    defer std.Io.Dir.cwd().deleteFile(io(), path) catch {};

    const Engine = @import("engine.zig").Engine;
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();
    const ctx = engine.currentContext();
    installRealm(std.testing.allocator, ctx, engine.currentGlobalObject());

    // Write natively, then read the bytes back and check size/exists/text.
    _ = try evaluate.evaluateUtf8(std.testing.allocator, ctx,
        "globalThis.__w = null;" ++
        "Bun.write('/tmp/home_bun_unit_test.txt', 'bun-fs-roundtrip').then(function(n) {" ++
        "  var f = Bun.file('/tmp/home_bun_unit_test.txt');" ++
        "  return f.text().then(function(t) { globalThis.__w = n + ':' + f.size + ':' + t; });" ++
        "});",
        "home:bun-write-setup", 1, null);
    try std.testing.expect(try evalBool(std.testing.allocator, ctx,
        "globalThis.__w === '16:16:bun-fs-roundtrip'"));
}

test "Bun.file.exists reflects presence; missing file text() rejects" {
    if (!build_options.enable_jsc) return error.SkipZigTest;
    const Engine = @import("engine.zig").Engine;
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();
    const ctx = engine.currentContext();
    installRealm(std.testing.allocator, ctx, engine.currentGlobalObject());

    _ = try evaluate.evaluateUtf8(std.testing.allocator, ctx,
        "globalThis.__e = null;" ++
        "Bun.file('/tmp/home_definitely_missing_zzz.txt').exists().then(function(ex) {" ++
        "  Bun.file('/tmp/home_definitely_missing_zzz.txt').text().then(function() { globalThis.__e = 'resolved'; }, function() { globalThis.__e = ex + ':rejected'; });" ++
        "});",
        "home:bun-exists-setup", 1, null);
    try std.testing.expect(try evalBool(std.testing.allocator, ctx, "globalThis.__e === 'false:rejected'"));
}
